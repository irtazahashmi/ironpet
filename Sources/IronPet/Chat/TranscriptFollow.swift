import CoreGraphics
import IronPetKit

/// Last-resort repair for a transcript viewport that shows no rows although there is content to show.
///
/// A lazy stack can leave the offset past the rows it has laid out, so the viewport is empty until the reader scrolls.
/// This fires only when no row reports itself visible, the content is taller than the viewport, and the viewport
/// extends past the end of the content. The row reports alone lagged behind programmatic scroll jumps and flagged
/// healthy transcripts, so the scroll view's own geometry has to agree. It fires at most once for each content height,
/// so one layout pass cannot trigger a chain of scrolls. Any visible row re-arms it.
struct BlankViewportGuard {
    private var firedAtHeight: CGFloat?

    mutating func rowsVisible() { firedAtHeight = nil }

    mutating func shouldReanchor(visibleRows: Int, hasRows: Bool, contentHeight: CGFloat, viewportHeight: CGFloat,
                                 distanceFromBottom: CGFloat) -> Bool {
        if visibleRows > 0 {
            rowsVisible()
            return false
        }
        guard hasRows, viewportHeight > 0, contentHeight > viewportHeight,
              distanceFromBottom < -CGFloat(TranscriptFollowState.bottomTolerance), firedAtHeight != contentHeight else { return false }
        firedAtHeight = contentHeight
        return true
    }
}
