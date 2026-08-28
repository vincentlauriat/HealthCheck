import Foundation

protocol TimedHealthValue {
    var type: String { get }
    var sourceName: String { get }
    var startDate: Date { get }
    var endDate: Date { get }
}
