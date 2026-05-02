import SwiftUI

struct FilmstripView: View {
    @ObservedObject var viewModel: PhotoEditorViewModel
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(Array(viewModel.photoQueue.enumerated()), id: \.element.id) { index, asset in
                    Image(nsImage: asset.document.originalImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 80, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(viewModel.selectedIndex == index ? Color.accentColor : Color.clear, lineWidth: 3)
                        )
                        .onTapGesture {
                            viewModel.selectPhoto(at: index)
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: 80)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
