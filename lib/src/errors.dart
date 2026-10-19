import 'models.dart';
import 'rust/api.dart' as w;

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
  if (error is w.OpenLvFailure) {
    return OpenLvException(error.kind, error.message);
  }
  return OpenLvException(OpenLvErrorKind.other, '$error');
}
