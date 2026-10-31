import 'models.dart';
import 'uniffi/openlv_uniffi.dart' as native;

/// An error raised by the openlv SDK.
class OpenLvException implements Exception {
  final OpenLvErrorKind kind;
  final String message;

  const OpenLvException(this.kind, this.message);

  @override
  String toString() => 'OpenLvException(${kind.name}): $message';
}

OpenLvException openLvExceptionFrom(Object error) {
  if (error is OpenLvException) return error;
  if (error is native.BridgeErrorExceptionFailure) {
    final name = error.kind.replaceAllMapped(
      RegExp(r'_([a-z])'),
      (match) => match[1]!.toUpperCase(),
    );
    final kind = OpenLvErrorKind.values.where((value) => value.name == name);
    return OpenLvException(
      kind.isEmpty ? OpenLvErrorKind.other : kind.first,
      error.message,
    );
  }
  return OpenLvException(OpenLvErrorKind.other, '$error');
}
