//! Dart bridge API. JSON payloads cross FFI as strings.

use crate::frb_generated::StreamSink;
use flutter_rust_bridge::DartFnFuture;
use tokio::sync::broadcast;

use crate::runtime::{on_openlv_runtime, spawn};


/// Identity of a peer shared with the remote side during the handshake.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerInfo {
    pub identity: String,
    pub name: String,
    pub icon: Option<String>,
}

/// Lifecycle status of a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionStatus {
    Created,
    Signaling,
    Ready,
    Linking,
    Connected,
    Disconnected,
}

/// State of the signaling/handshake layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignalState {
    Standby,
    Connecting,
    Ready,
    Handshake,
    HandshakePartial,
    Encrypted,
    Error,
}

/// Snapshot of the full session state.
#[derive(Debug, Clone)]
pub struct SessionState {
    pub status: SessionStatus,
    pub signaling: Option<SignalState>,
    pub peer: Option<PeerInfo>,
    pub error: Option<String>,
}

/// Options for creating a host (dApp) session.
#[derive(Debug, Clone, Default)]
pub struct SessionOptions {
    /// Fixed session id (16 URL-safe characters). Auto-generated when omitted.
    pub session_id: Option<String>,
    /// Signaling protocol: `"ntfy"` or `"mqtt"`. Defaults to `"ntfy"`.
    pub protocol: Option<String>,
    /// Signaling server URL. Defaults to `"https://ntfy.sh/"`.
    pub server: Option<String>,
    /// Pre-shared handshake key as 32 hex characters. Auto-generated when
    /// omitted.
    pub handshake_key: Option<String>,
    /// Identity shared with the remote peer during the handshake.
    pub peer_info: Option<PeerInfo>,
}

/// The parsed contents of an `openlv://` connection URL.
#[derive(Debug, Clone)]
pub struct SessionUriInfo {
    pub session_id: String,
    pub key_hash: String,
    pub handshake_key: String,
    pub protocol: String,
    pub server: String,
}


/// Machine-readable category of an openlv failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenLvErrorKind {
    InvalidUri,
    Signaling,
    Transport,
    Session,
    Encryption,
    WireFrame,
    ProtocolViolation,
    UnsupportedProtocol,
    NoConnection,
    RequestTimeout,
    Other,
}

/// Error type surfaced to Dart as an exception.
#[derive(Debug, Clone)]
pub struct OpenLvFailure {
    pub kind: OpenLvErrorKind,
    pub message: String,
}

impl OpenLvFailure {
    pub(crate) fn new(kind: OpenLvErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for OpenLvFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for OpenLvFailure {}

impl From<openlv::OpenLvError> for OpenLvFailure {
    fn from(value: openlv::OpenLvError) -> Self {
        use openlv::OpenLvError as E;

        let kind = match &value {
            E::InvalidUri(_) => OpenLvErrorKind::InvalidUri,
            E::Signaling(_) => OpenLvErrorKind::Signaling,
            E::Transport(_) => OpenLvErrorKind::Transport,
            E::Session(_) => OpenLvErrorKind::Session,
            E::Encryption(_) => OpenLvErrorKind::Encryption,
            E::WireFrame(_) => OpenLvErrorKind::WireFrame,
            E::ProtocolViolation(_) => OpenLvErrorKind::ProtocolViolation,
            E::UnsupportedProtocol(_) => OpenLvErrorKind::UnsupportedProtocol,
            E::NoConnection => OpenLvErrorKind::NoConnection,
            E::RequestTimeout(_) => OpenLvErrorKind::RequestTimeout,
            E::Other(_) => OpenLvErrorKind::Other,
        };

        Self {
            kind,
            message: value.to_string(),
        }
    }
}


/// Start building a host (dApp) session.
///
/// The session is not connected until [`OpenLvSession::connect`] is called.
pub async fn create_dapp(
    options: SessionOptions,
    on_request: impl Fn(String) -> DartFnFuture<anyhow::Result<String>> + Send + Sync + 'static,
) -> Result<OpenLvSession, OpenLvFailure> {
    on_openlv_runtime(async move {
        let peer_info = options
            .peer_info
            .map(validate_peer_info)
            .transpose()?
            .map(openlv::PeerInfo::from);

        let mut config = openlv::dapp();
        if let Some(session_id) = options.session_id {
            config = config.session_id(session_id);
        }
        if let Some(protocol) = options.protocol {
            config = config.protocol(protocol);
        }
        if let Some(server) = options.server {
            config = config.server(server);
        }
        if let Some(handshake_key) = options.handshake_key {
            config = config.handshake_key(parse_handshake_key(&handshake_key)?);
        }
        if let Some(peer_info) = peer_info {
            config = config.info(peer_info);
        }

        let session = config
            .on_request(move |message| decode_dart_response(spawn(on_request(message.to_string()))))
            .await
            .map_err(OpenLvFailure::from)?;
        Ok(OpenLvSession::new(session))
    })
    .await
}

/// Start a client (wallet) session from an `openlv://` connection URL.
///
/// The session is not connected until [`OpenLvSession::connect`] is called.
pub async fn connect_wallet(
    url: String,
    peer_info: Option<PeerInfo>,
    on_request: impl Fn(String) -> DartFnFuture<anyhow::Result<String>> + Send + Sync + 'static,
) -> Result<OpenLvSession, OpenLvFailure> {
    on_openlv_runtime(async move {
        let peer_info = peer_info
            .map(validate_peer_info)
            .transpose()?
            .map(openlv::PeerInfo::from);

        let mut config = openlv::wallet(&url);
        if let Some(peer_info) = peer_info {
            config = config.info(peer_info);
        }

        let session = config
            .on_request(move |message| decode_dart_response(spawn(on_request(message.to_string()))))
            .await
            .map_err(OpenLvFailure::from)?;
        Ok(OpenLvSession::new(session))
    })
    .await
}

/// Parse an `openlv://` connection URL into its individual parameters.
pub fn parse_session_uri(url: String) -> Result<SessionUriInfo, OpenLvFailure> {
    let uri = openlv::SessionUri::from_url(&url).map_err(OpenLvFailure::from)?;
    let openlv::SessionUri::Version1(version1) = uri;

    Ok(SessionUriInfo {
        session_id: version1.session_id,
        key_hash: version1.key_hash.0,
        handshake_key: version1.shared_key.to_hex().to_string(),
        protocol: version1.signaling_protocol.to_string(),
        server: version1.signaling_server,
    })
}

/// Generate a random 16-character URL-safe session id.
pub fn generate_session_id() -> String {
    openlv::url::generate_session_id()
}


/// A live (or not-yet-connected) openlv session.
#[derive(Clone)]
pub struct OpenLvSession {
    inner: openlv::Session,
}

impl OpenLvSession {
    fn new(session: openlv::Session) -> Self {
        Self { inner: session }
    }

    /// Connect the signaling layer and start the handshake.
    pub async fn connect(&self) -> Result<(), OpenLvFailure> {
        let session = self.inner.clone();
        on_openlv_runtime(async move { session.connect().await.map_err(Into::into) }).await
    }

    /// Wait until the peer-to-peer transport reports connected.
    pub async fn wait_for_link(&self) -> Result<(), OpenLvFailure> {
        let session = self.inner.clone();
        on_openlv_runtime(async move { session.wait_for_link().await.map_err(Into::into) }).await
    }

    /// Send a JSON-encoded request and wait for its JSON-encoded response,
    /// using the SDK-default timeouts (10s ack, 1h response).
    pub async fn send(&self, message_json: String) -> Result<String, OpenLvFailure> {
        let session = self.inner.clone();
        on_openlv_runtime(async move {
            let message = parse_json(&message_json)?;
            let response = session.send(message).await.map_err(OpenLvFailure::from)?;
            encode_json(&response)
        })
        .await
    }

    /// Send a JSON-encoded request with explicit ack/response timeouts.
    pub async fn send_with_timeouts(
        &self,
        message_json: String,
        ack_timeout_ms: u64,
        response_timeout_ms: u64,
    ) -> Result<String, OpenLvFailure> {
        let session = self.inner.clone();
        on_openlv_runtime(async move {
            let message = parse_json(&message_json)?;
            let response = session
                .send_with_timeouts(message, ack_timeout_ms, response_timeout_ms)
                .await
                .map_err(OpenLvFailure::from)?;
            encode_json(&response)
        })
        .await
    }

    /// Cancel pending operations and close the session.
    pub async fn close(&self) -> Result<(), OpenLvFailure> {
        let session = self.inner.clone();
        on_openlv_runtime(async move { session.close().await.map_err(Into::into) }).await
    }

    /// The current session state.
    pub fn state(&self) -> SessionState {
        map_session_state(self.inner.state())
    }

    /// Stream of session state updates. Ends when the session is closed.
    pub fn subscribe_states(&self, sink: StreamSink<SessionState>) {
        let mut receiver = self.inner.subscribe_state();
        let session = self.inner.clone();
        spawn(async move {
            let closed = session.closed();
            tokio::pin!(closed);
            loop {
                let event = tokio::select! {
                    biased;
                    _ = &mut closed => break,
                    event = receiver.recv() => event,
                };
                match event {
                    Ok(state) => {
                        if sink.add(map_session_state(state)).is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    /// Whether this side is the host (dApp) of the session.
    pub fn is_host(&self) -> bool {
        self.inner.is_host()
    }

    /// The `openlv://` connection URL of this session.
    pub fn uri(&self) -> String {
        self.inner.uri().to_string()
    }

    /// The 16-character session id.
    pub fn session_id(&self) -> String {
        match self.inner.uri() {
            openlv::SessionUri::Version1(version1) => version1.session_id.clone(),
        }
    }
}


// Keep FRB's response receiver alive until Dart finishes, even after shutdown.
async fn decode_dart_response(
    response: tokio::task::JoinHandle<anyhow::Result<String>>,
) -> Result<serde_json::Value, openlv::OpenLvError> {
    let response = response
        .await
        .map_err(|error| openlv::OpenLvError::Other(format!("Dart handler task failed: {error}")))?
        .map_err(|error| openlv::OpenLvError::Other(error.to_string()))?;
    serde_json::from_str(&response).map_err(Into::into)
}

fn parse_handshake_key(hex: &str) -> Result<openlv::encryption::HandshakeKey, OpenLvFailure> {
    openlv::encryption::HandshakeKey::from_hex(hex).map_err(OpenLvFailure::from)
}

fn validate_peer_info(info: PeerInfo) -> Result<PeerInfo, OpenLvFailure> {
    let openlv_info = openlv::PeerInfo::from(info.clone());
    openlv_info
        .validate()
        .map_err(|reason| OpenLvFailure::new(OpenLvErrorKind::Session, reason))?;
    Ok(info)
}

fn parse_json(value: &str) -> Result<serde_json::Value, OpenLvFailure> {
    serde_json::from_str(value)
        .map_err(|error| OpenLvFailure::new(OpenLvErrorKind::Other, error.to_string()))
}

fn encode_json(value: &serde_json::Value) -> Result<String, OpenLvFailure> {
    serde_json::to_string(value)
        .map_err(|error| OpenLvFailure::new(OpenLvErrorKind::Other, error.to_string()))
}

fn map_session_state(state: openlv::SessionStateObject) -> SessionState {
    SessionState {
        status: map_status(state.status),
        signaling: state.signaling.map(map_signal_state),
        peer: state.peer_info.map(map_peer_info),
        error: state.error,
    }
}

fn map_status(status: openlv::SessionState) -> SessionStatus {
    match status {
        openlv::SessionState::Created => SessionStatus::Created,
        openlv::SessionState::Signaling => SessionStatus::Signaling,
        openlv::SessionState::Ready => SessionStatus::Ready,
        openlv::SessionState::Linking => SessionStatus::Linking,
        openlv::SessionState::Connected => SessionStatus::Connected,
        openlv::SessionState::Disconnected => SessionStatus::Disconnected,
    }
}

fn map_signal_state(state: openlv::SignalState) -> SignalState {
    match state {
        openlv::SignalState::Standby => SignalState::Standby,
        openlv::SignalState::Connecting => SignalState::Connecting,
        openlv::SignalState::Ready => SignalState::Ready,
        openlv::SignalState::Handshake => SignalState::Handshake,
        openlv::SignalState::HandshakePartial => SignalState::HandshakePartial,
        openlv::SignalState::Encrypted => SignalState::Encrypted,
        openlv::SignalState::Error => SignalState::Error,
    }
}

fn map_peer_info(info: openlv::PeerInfo) -> PeerInfo {
    PeerInfo {
        identity: info.identity,
        name: info.name,
        icon: info.icon,
    }
}

impl From<PeerInfo> for openlv::PeerInfo {
    fn from(value: PeerInfo) -> Self {
        Self {
            identity: value.identity,
            name: value.name,
            icon: value.icon,
        }
    }
}
