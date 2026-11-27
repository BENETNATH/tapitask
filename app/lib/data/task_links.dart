Uri? taskLink(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != "https" && uri.scheme != "http") ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

Iterable<Uri> taskLinks(String text) =>
    RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false)
        .allMatches(text)
        .map((match) =>
            taskLink(match[0]!.replaceFirst(RegExp(r"[.,;!?)\]}]+$"), "")))
        .whereType<Uri>()
        .toSet();
