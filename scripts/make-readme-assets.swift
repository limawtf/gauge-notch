import AppKit

// Gera assets do README.
//   swift scripts/make-readme-assets.swift banner <AppIcon.icns> <out.png>
//   swift scripts/make-readme-assets.swift frames <outdir> <png1> <png2> ...
// "frames" emite PNGs em ALTA resolucao (hold + crossfade, alinhados ao topo) num diretorio;
// o make-gif.sh encoda com ffmpeg palettegen/paletteuse (GIF nitido, sem banding).

func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 0xFF)/255, green: CGFloat((h >> 8) & 0xFF)/255,
            blue: CGFloat(h & 0xFF)/255, alpha: a)
}

func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func writePNG(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// ---------------------------------------------------------------- banner
func makeBanner(icon iconPath: String, out: String) {
    let W = 1200, H = 400
    let rep = bitmap(W, H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    let full = NSRect(x: 0, y: 0, width: W, height: H)

    NSGradient(colors: [hex(0x181820), hex(0x0b0b0f)])!.draw(in: NSBezierPath(rect: full), angle: 315)

    // motivo: arco esmeralda leve no canto direito
    let cA = NSPoint(x: W - 150, y: H/2)
    let arc = NSBezierPath()
    arc.appendArc(withCenter: cA, radius: 240, startAngle: 150, endAngle: -60, clockwise: true)
    arc.lineWidth = 20; arc.lineCapStyle = .round
    hex(0x34d399, 0.10).setStroke(); arc.stroke()

    // icone
    if let img = NSImage(contentsOfFile: iconPath) {
        let s: CGFloat = 260
        img.draw(in: NSRect(x: 96, y: (CGFloat(H)-s)/2, width: s, height: s))
    }

    let tx: CGFloat = 400
    let title = NSAttributedString(string: "Gauge", attributes: [
        .font: NSFont.systemFont(ofSize: 108, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    title.draw(at: NSPoint(x: tx, y: 205))

    // sublinhado esmeralda curto
    let ul = NSBezierPath(roundedRect: NSRect(x: tx + 4, y: 188, width: 96, height: 7),
                          xRadius: 3.5, yRadius: 3.5)
    hex(0x34d399).setFill(); ul.fill()

    let tagline = NSAttributedString(string: "Seu uso do Claude, vivo no notch do Mac.", attributes: [
        .font: NSFont.systemFont(ofSize: 34, weight: .medium),
        .foregroundColor: hex(0x9a9aa6),
    ])
    tagline.draw(at: NSPoint(x: tx, y: 120))

    NSGraphicsContext.restoreGraphicsState()
    writePNG(rep, out)
    print("banner: \(out)")
}

// ---------------------------------------------------------------- frames do tour
// Emite PNGs em alta resolucao (sem downscale) pro ffmpeg montar o GIF. Frames alinhados
// ao TOPO (o painel desce do notch), fundo chapado (sem gradiente = sem banding no GIF).
func frame(_ W: Int, _ H: Int, pad: CGFloat, bg: NSColor, layers: [(NSImage, CGFloat)]) -> NSBitmapImageRep {
    let rep = bitmap(W, H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    bg.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H)).fill()
    for (img, alpha) in layers where alpha > 0.001 {
        let x = (CGFloat(W) - img.size.width) / 2      // centrado na horizontal
        // cabe na tela: centraliza (fica equilibrado). Mais alto que a tela (Consumo):
        // alinha no topo pra mostrar o header e deixa o excedente vazar/some no fade.
        let fits = img.size.height <= CGFloat(H) - 2*pad
        let y = fits ? (CGFloat(H) - img.size.height) / 2 : CGFloat(H) - pad - img.size.height
        img.draw(in: NSRect(x: x, y: y, width: img.size.width, height: img.size.height),
                 from: .zero, operation: .sourceOver, fraction: alpha)
    }
    // fade embaixo: esconde o corte do painel Consumo (mais alto que a tela)
    let fadeH: CGFloat = 130
    NSGradient(colors: [bg, bg.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: Int(fadeH))), angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func emitFrames(dir: String, pngs: [String]) {
    let imgs = pngs.map { NSImage(contentsOfFile: $0)! }   // resolucao nativa (@2x)
    let pad: CGFloat = 48
    let W = Int(imgs.map { $0.size.width }.max()! + 2*pad)
    // capa a altura pra nao sobrar area morta com o painel Consumo (bem mais alto);
    // o excedente vaza pra baixo e some no fade.
    let contentH = min(imgs.map { $0.size.height }.max()!, 840)
    let H = Int(contentH + 2*pad)
    let bg = hex(0x0a0a0c)
    let hold = 16, xFrames = 6   // a 12 fps: hold ~1.33s, crossfade ~0.5s

    var reps: [NSBitmapImageRep] = []
    for i in imgs.indices {
        let a = imgs[i], b = imgs[(i + 1) % imgs.count]
        for _ in 0..<hold { reps.append(frame(W, H, pad: pad, bg: bg, layers: [(a, 1)])) }
        for k in 1...xFrames {
            let t = CGFloat(k) / CGFloat(xFrames + 1)
            reps.append(frame(W, H, pad: pad, bg: bg, layers: [(a, 1 - t), (b, t)]))
        }
    }
    for (n, rep) in reps.enumerated() {
        let name = String(format: "frame_%04d.png", n + 1)
        writePNG(rep, "\(dir)/\(name)")
    }
    print("frames: \(reps.count) em \(dir)  (\(W)x\(H))")
}

// ---------------------------------------------------------------- main
let a = CommandLine.arguments
switch a.count >= 2 ? a[1] : "" {
case "banner" where a.count >= 4: makeBanner(icon: a[2], out: a[3])
case "frames" where a.count >= 4: emitFrames(dir: a[2], pngs: Array(a[3...]))
default:
    FileHandle.standardError.write(Data("uso: banner <icns> <out.png> | frames <dir> <png...>\n".utf8))
    exit(1)
}
