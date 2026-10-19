// Run from the openlv-dart root after building the Rust wrapper:
// dart tool/generate_bindings.dart rust/target/debug/libopenlv_dart_ffi.so
// Requires uniffi-bindgen-dart 0.2.0. ABI checks remain enabled.
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/generate_bindings.dart <native-library>',
    );
    exit(64);
  }
  final output = Directory('lib/src/uniffi')..createSync(recursive: true);
  // Without `--crate`, the generator prefixes the runtime symbols with
  // `ffi_uniffi_openlv_ffi_`, but the library exports `ffi_openlv_ffi_`.
  final result = await Process.run('uniffi-bindgen-dart', [
    'generate',
    args.single,
    '--crate',
    'openlv_ffi',
    '--out-dir',
    output.path,
    '--no-format',
  ]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) exit(result.exitCode);
}
