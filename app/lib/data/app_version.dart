/// Version de l'app consommée par les comparaisons de mise à jour.
/// Injectée au build release via `--dart-define=APP_VERSION=<tag sans v>`
/// (workflow release-artifacts) ; 'dev' en build local/test. Le pubspec
/// (0.1.0, jamais bumpé) n'est PAS la source.
library;

const String appVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
