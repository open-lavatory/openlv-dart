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
  final result = await Process.run('uniffi-bindgen-dart', [
    'generate',
    args.single,
    '--out-dir',
    output.path,
    '--no-format',
  ]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) exit(result.exitCode);
  final generated = File('${output.path}/openlv_ffi.dart');
  final source = generated.readAsStringSync();
  // uniffi-bindgen-dart 0.2.0 adds an erroneous `uniffi_` to the runtime
  // symbol prefix. Do not change the other symbols or disable ABI checks.
  const wrong = 'ffi_uniffi_openlv_ffi_';
  if (!source.contains(wrong)) {
    throw StateError(
      'Expected uniffi-bindgen-dart runtime symbol bug not found',
    );
  }
  var patched = source.replaceAll(wrong, 'ffi_openlv_ffi_');
  // The generator decodes UniFFI's async boolean as int but returns Future<bool>.
  const boolean = '''final int resultValue = _sessionIsHostFfiBufferRustFutureComplete(futureHandle, outStatusPtr);
          final int completeStatusCode = outStatusPtr.ref.code;
          if (completeStatusCode == _uniFfiRustCallStatusSuccess) {
            return resultValue;''';
  if (!patched.contains(boolean)) {
    throw StateError(
      'Expected uniffi-bindgen-dart async boolean bug not found',
    );
  }
  patched = patched.replaceFirst(
    boolean,
    boolean.replaceFirst('return resultValue;', 'return resultValue != 0;'),
  );
  File('${output.path}/openlv_uniffi.dart').writeAsStringSync(patched);
  generated.deleteSync();
}
