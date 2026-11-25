import Foundation
import IronPetKit

extension ElicitationForm {
    /// The fields grouped into pages, one page per question. See `ElicitationPaging.pages(ids:)`.
    package var pages: [[ElicitationField]] {
        ElicitationPaging.pages(ids: fields.map(\.id)).map { $0.map { fields[$0] } }
    }

    /// The first page whose required fields are empty or whose number does not parse, or nil when the form can be submitted.
    package func firstIncompletePage(_ answers: ElicitationAnswers) -> Int? {
        pages.firstIndex { !ElicitationForm(message: "", fields: $0).canSubmit(answers) }
    }
}
