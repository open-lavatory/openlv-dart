// Builds the `openlv_ffi` Rust glue crate with cargo and registers the
// resulting native library as a code asset.
//
// Configuration via `hooks.user_defines.openlv` in the consuming application's
// pubspec.yaml:
//
// ```yaml
// hooks:
//   user_defines:
//     openlv:
//       profile: debug   # or 'release' (default)
// ```
//
// `OPENLV_CARGO_PROFILE` takes precedence over user-defines.
import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// Library file stem; must match the crate name in rust/Cargo.toml and the
/// loader in lib/src/loader.dart.
const String _stem = 'openlv_ffi';

/// Asset name; must match `_kAssetId` in lib/src/loader.dart.
const String _assetName = 'src/native/openlv_ffi.g.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;
    final targetOS = code.targetOS;
    final architecture = code.targetArchitecture;

    final ios = targetOS == OS.iOS ? code.iOS : null;
    final triple = _rustTargetTriple(targetOS, architecture, ios?.targetSdk);
    if (triple == null) {
      throw StateError(
        'openlv: unsupported target ${architecture.name}-${targetOS.name}'
        '${ios == null ? '' : ' (${ios.targetSdk.type})'}. '
        'Supported: linux, macos, windows and android on supported Rust '
        'architectures; ios devices on arm64 and simulators on arm64 or x64.',
      );
    }

    // Track Rust edits so the hook cache cannot serve a stale library.
    for (final file in _rustSources(input.packageRoot.resolve('rust/'))) {
      output.dependencies.add(file);
    }

    final profile = _cargoProfile(input);
    // Static linking is required by invokers such as iOS release builds.
    final useStatic = code.linkModePreference == LinkModePreference.static;

    final crateRoot = input.packageRoot.resolve('rust/');

    final targetRoot = await _runCargo(
      crateRoot: crateRoot,
      triple: triple,
      profile: profile,
      cCompiler: code.cCompiler,
      targetOS: targetOS,
      ios: ios,
    );

    final fileName = useStatic
        ? targetOS.staticlibFileName(_stem)
        : targetOS.dylibFileName(_stem);
    final file = targetRoot.resolve('$triple/$profile/$fileName');

    final linkMode = useStatic ? StaticLinking() : DynamicLoadingBundled();

    if (!File.fromUri(file).existsSync()) {
      throw StateError(
        'openlv: cargo did not produce the expected artifact at '
        '${file.toFilePath()}.',
      );
    }

    final bundled = input.outputDirectory.resolve(fileName);
    File.fromUri(file).copySync(bundled.toFilePath());

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: linkMode,
        file: bundled,
      ),
    );
  });
}

/// Rust sources, manifests and lockfiles used to invalidate the hook cache.
Iterable<Uri> _rustSources(Uri rustRoot) sync* {
  final root = Directory.fromUri(rustRoot);
  if (!root.existsSync()) return;

  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File) continue;
    if (entity.path.split(Platform.pathSeparator).contains('target')) continue;
    final name = entity.uri.pathSegments.last;
    if (name.endsWith('.rs') || name == 'Cargo.toml' || name == 'Cargo.lock') {
      yield entity.uri;
    }
  }
}

/// Environment override, then user-defines, then `release`.
String _cargoProfile(BuildInput input) {
  final define =
      input.userDefines['profile'] ?? input.userDefines['cargo_profile'];
  final fromEnv = Platform.environment['OPENLV_CARGO_PROFILE'];
  final profile = (fromEnv ?? (define is String ? define : null)) ?? 'release';

  if (profile != 'debug' && profile != 'release') {
    throw StateError(
      "openlv: invalid cargo profile '$profile' (expected 'debug' or 'release').",
    );
  }
  return profile;
}

Future<Uri> _runCargo({
  required Uri crateRoot,
  required String triple,
  required String profile,
  required CCompilerConfig? cCompiler,
  required OS targetOS,
  required IOSCodeConfig? ios,
}) async {
  final environment = Map<String, String>.of(Platform.environment);

  if (ios != null) {
    // Both rustc's linker and cc-rs must use the selected Xcode SDK, not
    // whichever SDK happens to be selected by the host environment.
    final sdk = await Process.run('xcrun', [
      '--sdk',
      ios.targetSdk.type,
      '--show-sdk-path',
    ]);
    if (sdk.exitCode != 0 || (sdk.stdout as String).trim().isEmpty) {
      throw StateError(
        'openlv: could not resolve ${ios.targetSdk.type} SDK: ${sdk.stderr}',
      );
    }
    environment['SDKROOT'] = (sdk.stdout as String).trim();
    environment['IPHONEOS_DEPLOYMENT_TARGET'] = '${ios.targetVersion}.0';
  }

  // Cross-builds use the configured target toolchain; host builds keep defaults.
  if (cCompiler != null && targetOS != OS.current) {
    final compiler = cCompiler.compiler.toFilePath();
    final archiver = cCompiler.archiver.toFilePath();
    final targetKey = triple.toUpperCase().replaceAll('-', '_');

    // The NDK's plain clang driver has no API-level context: it does not add
    // `sysroot/usr/lib/<triple>/<api>/` to the link search paths, so `-llog`
    // and friends fail to resolve. The API-suffixed wrapper drivers do.
    final linker = targetOS == OS.android
        ? _androidClangWrapper(compiler, triple) ?? compiler
        : compiler;

    environment['CARGO_TARGET_${targetKey}_LINKER'] = linker;
    environment['CC_$triple'] = linker;
    environment['AR_$triple'] = archiver;
    environment['TARGET_CC'] = linker;
    environment['TARGET_AR'] = archiver;

    // cc-rs forces `-mthumb` for Android armv7, but the asm sources of e.g.
    // `ring` use ARM-only instructions (`strd`), which are invalid in thumb
    // mode. Respect any explicit user flag; otherwise force ARM mode.
    if (triple == 'armv7-linux-androideabi') {
      const cflagsKey = 'CFLAGS_armv7-linux-androideabi';
      environment[cflagsKey] ??= '-marm';
    }
  }

  final arguments = <String>[
    'build',
    '--locked',
    '--manifest-path',
    crateRoot.resolve('Cargo.toml').toFilePath(),
    '--target',
    triple,
    if (profile == 'release') '--release',
  ];

  final process = await Process.start(
    'cargo',
    arguments,
    workingDirectory: crateRoot.toFilePath(),
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );

  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw StateError(
      'openlv: `cargo ${arguments.join(' ')}` failed with exit code $exitCode.',
    );
  }

  // Use Cargo's target-directory resolution with the same cwd and environment.
  final metadata = await Process.run(
    'cargo',
    ['metadata', '--no-deps', '--format-version', '1', '--locked'],
    workingDirectory: crateRoot.toFilePath(),
    environment: environment,
  );
  if (metadata.exitCode != 0) {
    throw StateError(
      'openlv: cargo metadata failed with exit code ${metadata.exitCode}: '
      '${metadata.stderr}',
    );
  }
  final data = jsonDecode(metadata.stdout as String) as Map<String, dynamic>;
  return Directory(data['target_directory'] as String).uri;
}

/// Lowest NDK API level the wrapper uses for linking. `21` covers Flutter's
/// minimum supported Android SDK.
const _androidMinApiLevel = 21;

/// Resolve the NDK's API-suffixed clang wrapper for [rustTriple] from the
/// plain clang [compilerPath] that the build provides, or null when the
/// compiler is already a wrapper or the wrapper is missing.
String? _androidClangWrapper(String compilerPath, String rustTriple) {
  if (RegExp(r'-(19|[2-9][0-9])-clang$').hasMatch(compilerPath)) {
    return null;
  }
  final bin = File(compilerPath).parent.path;
  // Rust's armv7 triple uses the NDK's `armv7a` naming.
  final ndkTriple = rustTriple == 'armv7-linux-androideabi'
      ? 'armv7a-linux-androideabi'
      : rustTriple;
  final wrapper = '$bin/$ndkTriple$_androidMinApiLevel-clang';
  return File(wrapper).existsSync() ? wrapper : null;
}

/// Rust target triple for the given OS, architecture and optional iOS SDK.
String? _rustTargetTriple(OS os, Architecture architecture, IOSSdk? iosSdk) {
  if (os == OS.android) {
    return switch (architecture) {
      Architecture.arm64 => 'aarch64-linux-android',
      Architecture.arm || Architecture.arm64e => 'armv7-linux-androideabi',
      Architecture.x64 => 'x86_64-linux-android',
      Architecture.ia32 => 'i686-linux-android',
      Architecture.riscv64 => 'riscv64-linux-android',
      _ => null,
    };
  }
  if (os == OS.iOS) {
    if (iosSdk == IOSSdk.iPhoneSimulator) {
      return switch (architecture) {
        Architecture.arm64 => 'aarch64-apple-ios-sim',
        Architecture.x64 => 'x86_64-apple-ios',
        _ => null,
      };
    }
    if (iosSdk == IOSSdk.iPhoneOS && architecture == Architecture.arm64) {
      return 'aarch64-apple-ios';
    }
    return null;
  }
  if (os == OS.macOS) {
    return switch (architecture) {
      Architecture.arm64 || Architecture.arm64e => 'aarch64-apple-darwin',
      Architecture.x64 => 'x86_64-apple-darwin',
      _ => null,
    };
  }
  if (os == OS.linux) {
    return switch (architecture) {
      Architecture.arm64 => 'aarch64-unknown-linux-gnu',
      Architecture.arm => 'armv7-unknown-linux-gnueabihf',
      Architecture.x64 => 'x86_64-unknown-linux-gnu',
      Architecture.ia32 => 'i686-unknown-linux-gnu',
      Architecture.riscv64 => 'riscv64gc-unknown-linux-gnu',
      _ => null,
    };
  }
  if (os == OS.windows) {
    return switch (architecture) {
      Architecture.arm64 => 'aarch64-pc-windows-msvc',
      Architecture.x64 => 'x86_64-pc-windows-msvc',
      Architecture.ia32 => 'i686-pc-windows-msvc',
      _ => null,
    };
  }
  return null;
}
