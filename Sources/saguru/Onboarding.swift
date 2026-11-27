import AppKit
import SwiftUI

// The introduction shown the first time the panel is unfolded: what Saguru is, that it works on one app,
// what it adds to the Simulator, and the one permission some tools need. It can be skipped at any step and
// seen again from the panel's menu. The pictures are in the app's resources (assets/onboarding).

struct OnboardingView: View {
    @ObservedObject var model: PanelModel
    @State private var step = 0
    @State private var forward = true
    @State private var trusted = SimulatorAX.trusted

    private struct Page {
        let picture: String
        let symbol: String
        let title: String
        let text: String
    }

    private let pages = [
        Page(picture: "step1", symbol: "chevron.right.2", title: "Bienvenido a Saguru",
             text: "Un panel que vive pegado a tu Simulador de iOS. Lo despliegas con » cuando lo necesitas y lo pliegas cuando no: nunca tapa tu trabajo."),
        Page(picture: "step2", symbol: "square.grid.3x3", title: "Empieza por elegir tu app",
             text: "Saguru trabaja sobre una app del simulador. Al elegirla verás su versión, su compilación y lo que declara, y todas las herramientas apuntarán a ella."),
        Page(picture: "step3", symbol: "wand.and.stars", title: "Lo que al simulador le falta",
             text: "Mira y sustituye lo que tu app le pide al servidor, dale una cámara, lee su consola y por qué se cerró. Algunas herramientas relanzan la app para entrar en ella; Saguru te lo dice antes de hacerlo."),
        Page(picture: "step4", symbol: "checkmark.seal", title: "Todo listo",
             text: "Las herramientas de diseño (cuadrícula, reglas, colores y accesibilidad) leen la ventana del Simulador, y macOS pide permiso para eso. Puedes darlo ahora o cuando las uses."),
    ]

    private static let tools: [(String, String)] = [("network", "Red"), ("camera", "Cámara"), ("terminal", "Registro"), ("bell.badge", "Push"),
                                                    ("hand.raised", "Permisos"), ("externaldrive", "Datos"), ("grid", "Diseño")]

    var body: some View {
        let page = pages[step]
        VStack(spacing: 0) {
            HStack {
                Text("Saguru").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Saltar introducción") { finish() }.buttonStyle(.borderless).controlSize(.small)
            }
            .padding(.horizontal, 22).padding(.top, 16)

            Spacer(minLength: 12)
            VStack(spacing: 22) {
                picture(page)
                VStack(spacing: 10) {
                    Text(page.title).font(.system(size: 28, weight: .bold)).multilineTextAlignment(.center)
                    Text(page.text).font(.system(size: 14.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .lineSpacing(3).frame(maxWidth: 470).fixedSize(horizontal: false, vertical: true)
                }
                if step == 2 { chips }
                if step == 3 { permission }
            }
            .padding(.horizontal, 30)
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            Spacer(minLength: 12)

            HStack(spacing: 14) {
                Button("Atrás") { go(-1) }.buttonStyle(.borderless).opacity(step == 0 ? 0 : 1).disabled(step == 0)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule().fill(index == step ? Color(nsColor: .systemBlue) : Color.white.opacity(0.22))
                            .frame(width: index == step ? 22 : 7, height: 7)
                    }
                }
                .accessibilityElement().accessibilityLabel("Paso \(step + 1) de \(pages.count)")
                Spacer()
                Button(step == pages.count - 1 ? "Empezar" : "Siguiente") { step == pages.count - 1 ? finish() : go(1) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 26).padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(red: 0.11, green: 0.12, blue: 0.22), Color(red: 0.06, green: 0.065, blue: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in trusted = SimulatorAX.trusted }
        .onExitCommand { finish() }
    }

    private func go(_ by: Int) {
        forward = by > 0
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = min(max(step + by, 0), pages.count - 1) }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboarding.done")
        withAnimation(.easeOut(duration: 0.25)) { model.onboarding = false }
        if model.openTool == nil { model.unfold() }
    }

    /// The step's picture, or its symbol on a soft glow when the pictures are not in the app.
    @ViewBuilder private func picture(_ page: Page) -> some View {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("onboarding/\(page.picture).jpg"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 460, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                .accessibilityHidden(true)
        } else {
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(nsColor: .systemBlue).opacity(0.5), .clear], center: .center, startRadius: 4, endRadius: 120))
                Image(systemName: page.symbol).font(.system(size: 64, weight: .medium)).foregroundStyle(.white)
            }
            .frame(width: 240, height: 200).accessibilityHidden(true)
        }
    }

    /// Two short rows rather than one long one: the panel can be narrow.
    private var chips: some View {
        VStack(spacing: 8) {
            ForEach([Array(Self.tools.prefix(4)), Array(Self.tools.dropFirst(4))], id: \.first?.1) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.1) { symbol, name in
                        HStack(spacing: 5) {
                            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                            Text(name).font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    }
                }
            }
        }
    }

    private var permission: some View {
        HStack(spacing: 10) {
            if trusted {
                Label("Permiso de Accesibilidad concedido", systemImage: "checkmark.circle.fill").foregroundStyle(Color(nsColor: .systemGreen))
            } else {
                Button("Dar permiso de Accesibilidad") {
                    SimulatorAX.requestAccess()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                }
                Text("Opcional").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}
