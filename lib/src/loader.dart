// FRB's generated IO bindings use its internal ExternalLibrary export.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;

import 'errors.dart';
import 'models.dart';
import 'rust/frb_generated.dart';

const String _kAssetId = 'package:openlv/src/native/openlv_ffi.g.dart';

const String _kStem = 'openlv_ffi';

// Load the bundled native asset and get its path for FRB's dynamic lookups.
@Native<Pointer<Utf8> Function()>(
  assetId: _kAssetId,
  symbol: 'openlv_ffi_bootstrap',
)
external Pointer<Utf8> _bootstrapPath();

Future<void>? _initFuture;

/// Load the openlv native library and initialize the bindings.
///
/// Initialization is shared within each isolate. Failed attempts can be retried.
///
/// Resolution order:
/// 1. an explicit [libraryPath] (absolute or relative to the working
///    directory),
/// 2. the `OPENLV_LIBRARY_PATH` environment variable,
/// 3. the process image (for statically linked builds),
/// 4. the bundled native asset (via the bootstrap anchor),
/// 5. `rust/target/{release,debug}/` next to the working directory and common
///    locations next to the running executable,
/// 6. the flutter_rust_bridge default loader.
Future<void> initOpenLv({String? libraryPath}) {
  final pending = _initFuture;
  if (pending != null) return pending;

  final completer = Completer<void>();
  _initFuture = completer.future;

  _doInit(libraryPath).then(
    (_) {
      completer.complete();
    },
    onError: (Object error, StackTrace stackTrace) {
      _initFuture = null;
      completer.completeError(error, stackTrace);
    },
  );

  return completer.future;
}

Future<void> _doInit(String? libraryPath) async {
  final failures = <String>[];

  Future<bool> tryCandidates(Iterable<String> candidates) async {
    for (final candidate in candidates) {
      if (candidate.isEmpty) continue;
      try {
        final handle = DynamicLibrary.open(candidate);
        handle.lookup('openlv_ffi_bootstrap');
        await RustLib.init(externalLibrary: ExternalLibrary.open(candidate));
        return true;
      } catch (error) {
        failures.add('$candidate: $error');
      }
    }
    return false;
  }

  if (await tryCandidates([
    ?libraryPath,
    ?Platform.environment['OPENLV_LIBRARY_PATH'],
  ])) {
    return;
  }

  try {
    DynamicLibrary.process().lookup('openlv_ffi_bootstrap');
    await RustLib.init(
      externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
    );
    return;
  } catch (error) {
    failures.add('process image: $error');
  }

  if (await tryCandidates([
    ..._bootstrapCandidates(),
    ..._discoveredCandidates(),
  ])) {
    return;
  }

  try {
    await RustLib.init();
    return;
  } catch (error) {
    failures.add('flutter_rust_bridge default loader: $error');
  }

  throw OpenLvException(
    OpenLvErrorKind.other,
    'Failed to load the openlv native library ($_kStem). '
    'Build it with `cargo build` in `rust/` (or run a build with native '
    'assets enabled), or pass an explicit libraryPath to OpenLv.init().\n'
    'Tried:\n${failures.join('\n')}',
  );
}

Iterable<String> _bootstrapCandidates() sync* {
  try {
    final path = _bootstrapPath().toDartString();
    if (path.isNotEmpty) yield path;
  } catch (_) {
    // Native assets are optional.
  }
}

Iterable<String> _discoveredCandidates() sync* {
  final name = switch (Platform.operatingSystem) {
    'windows' => '$_kStem.dll',
    'macos' || 'ios' => 'lib$_kStem.dylib',
    _ => 'lib$_kStem.so',
  };

  final executableDir = File(Platform.resolvedExecutable).parent.path;
  final directories = <String>[
    'rust/target/release',
    'rust/target/debug',
    executableDir,
    '$executableDir/lib',
    // macOS application bundles place dynamic libraries in Frameworks/.
    '$executableDir/../Frameworks',
  ];

  for (final directory in directories) {
    final path = '$directory${Platform.pathSeparator}$name';
    if (File(path).existsSync()) yield path;
  }
}
