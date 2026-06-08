import SwiftUI

struct SplashScreenView: View {
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                appIcon
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)
            }
            .transition(.opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.3)) {
                    logoScale = 1.0
                    logoOpacity = 1.0
                }
                withAnimation(.easeIn(duration: 0.2).delay(0.45)) {
                    logoOpacity = 0
                    logoScale = 1.1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.easeIn(duration: 0.2)) {
                        dismissed = true
                    }
                }
            }
        }
    }

    private var appIcon: some View {
        Group {
            if let uiImage = UIImage(named: "AppIcon") {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
            }
        }
    }
}
