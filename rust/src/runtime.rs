//! Runs SDK futures on Tokio; flutter_rust_bridge's executor has no Tokio context.

use std::future::Future;
use std::sync::OnceLock;

use crate::api::{OpenLvErrorKind, OpenLvFailure};

pub(crate) fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .thread_name("openlv")
            .enable_all()
            .build()
            .expect("failed to build the openlv tokio runtime")
    })
}

pub(crate) fn spawn<F>(future: F) -> tokio::task::JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    runtime().spawn(future)
}

pub(crate) async fn on_openlv_runtime<F, T>(future: F) -> Result<T, OpenLvFailure>
where
    F: Future<Output = Result<T, OpenLvFailure>> + Send + 'static,
    T: Send + 'static,
{
    match runtime().spawn(future).await {
        Ok(result) => result,
        Err(error) => Err(OpenLvFailure::new(
            OpenLvErrorKind::Other,
            format!("openlv task failed: {error}"),
        )),
    }
}
