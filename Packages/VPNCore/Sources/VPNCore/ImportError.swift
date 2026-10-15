/// Import errors. Messages are shown to the user and never contain secrets.
public enum ImportError: Error, Equatable, Sendable {
    case unsupportedScheme(String)
    case malformedLink(String)
    case missingField(String)
    case unsupportedTransport(String)
    case unsupportedFormat(String)
    case unrecognizedFormat
    case emptySubscription
    case nothingImported(String)
    case invalidSubscriptionURL
    case httpStatus(Int)
    case tooLarge
    case network(String)

    public var message: String {
        switch self {
        case .unsupportedScheme(let scheme):
            "Протокол \(scheme) пока не поддерживается"
        case .malformedLink(let detail):
            "Ссылка повреждена: \(detail)"
        case .missingField(let field):
            "В ключе не хватает поля: \(field)"
        case .unsupportedTransport(let transport):
            "Транспорт \(transport) пока не поддерживается"
        case .unsupportedFormat(let format):
            "Формат «\(format)» пока не поддерживается"
        case .unrecognizedFormat:
            "Не удалось распознать ключи или подписку"
        case .emptySubscription:
            "Подписка пустая"
        case .nothingImported(let reason):
            "Не удалось добавить ни одного сервера: \(reason)"
        case .invalidSubscriptionURL:
            "Ссылка на подписку должна начинаться с https://"
        case .httpStatus(let code):
            "Сервер подписки ответил ошибкой \(code)"
        case .tooLarge:
            "Подписка слишком большая"
        case .network(let detail):
            "Не удалось загрузить подписку: \(detail)"
        }
    }
}
