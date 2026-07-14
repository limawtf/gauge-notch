import AppKit

// Gera o master 1024x1024 do icone do Gauge (velocimetro minimalista, tema escuro).
// Uso: swift scripts/icon-gen.swift <saida.png>

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let S: CGFloat = 1024

func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255,
            green: CGFloat((h >> 8) & 0xFF) / 255,
            blue: CGFloat(h & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx

// --- squircle de fundo (grade macOS: arte ~824 com margem, cantos ~0.2237) ---
let inset: CGFloat = 100
let art = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let corner = art.width * 0.2237
let bg = NSBezierPath(roundedRect: art, xRadius: corner, yRadius: corner)

let grad = NSGradient(colors: [hex(0x262631), hex(0x0f0f14)])!
grad.draw(in: bg, angle: 270) // topo -> base

// brilho suave no topo pra dar profundidade
bg.setClip()
let glow = NSGradient(colors: [hex(0x3a3a4a, 0.55), hex(0x3a3a4a, 0.0)])!
glow.draw(fromCenter: NSPoint(x: S/2, y: art.maxY - 40), radius: 0,
          toCenter: NSPoint(x: S/2, y: art.maxY - 40), radius: art.width * 0.75,
          options: [])

// --- geometria do velocimetro ---
let c = NSPoint(x: S/2, y: S/2 - 40)
let R: CGFloat = 250
let startA: CGFloat = 210   // graus (AppKit: 0=leste, CCW), varre por cima
let endA: CGFloat = -30     // total 240 graus
let value: CGFloat = 0.64   // 64% do arco
let valEndA = startA - value * (startA - endA)

func arc(_ from: CGFloat, _ to: CGFloat, width: CGFloat, color: NSColor, glow: NSColor? = nil) {
    let p = NSBezierPath()
    p.appendArc(withCenter: c, radius: R, startAngle: from, endAngle: to, clockwise: true)
    p.lineWidth = width
    p.lineCapStyle = .round
    if let g = glow {
        let sh = NSShadow(); sh.shadowColor = g; sh.shadowBlurRadius = 34; sh.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState(); sh.set()
        color.setStroke(); p.stroke()
        NSGraphicsContext.restoreGraphicsState()
    } else {
        color.setStroke(); p.stroke()
    }
}

// trilha (fundo do medidor)
arc(startA, endA, width: 46, color: hex(0x3b3b46))
// valor (verde saude), com glow
arc(startA, valEndA, width: 46, color: hex(0x34d399), glow: hex(0x34d399, 0.9))

// ticks curtos ao longo do arco
let ticks = 6
for i in 0...ticks {
    let a = (startA - CGFloat(i) / CGFloat(ticks) * (startA - endA)) * .pi / 180
    let r1 = R + 42, r2 = R + 66
    let p = NSBezierPath()
    p.move(to: NSPoint(x: c.x + r1 * cos(a), y: c.y + r1 * sin(a)))
    p.line(to: NSPoint(x: c.x + r2 * cos(a), y: c.y + r2 * sin(a)))
    p.lineWidth = 9; p.lineCapStyle = .round
    hex(0x52525b).setStroke(); p.stroke()
}

// ponteiro (agulha) apontando pro valor
let a = valEndA * .pi / 180
let tip = NSPoint(x: c.x + (R - 34) * cos(a), y: c.y + (R - 34) * sin(a))
let perp = a + .pi / 2
let hw: CGFloat = 16
let base1 = NSPoint(x: c.x + hw * cos(perp), y: c.y + hw * sin(perp))
let base2 = NSPoint(x: c.x - hw * cos(perp), y: c.y - hw * sin(perp))
let needle = NSBezierPath()
needle.move(to: base1); needle.line(to: tip); needle.line(to: base2); needle.close()
do {
    let sh = NSShadow(); sh.shadowColor = hex(0x000000, 0.45); sh.shadowBlurRadius = 18
    sh.shadowOffset = NSSize(width: 0, height: -6)
    NSGraphicsContext.saveGraphicsState(); sh.set()
    hex(0xf7f7fa).setFill(); needle.fill()
    NSGraphicsContext.restoreGraphicsState()
}

// cubo central
let hubR: CGFloat = 44
let hub = NSBezierPath(ovalIn: NSRect(x: c.x - hubR, y: c.y - hubR, width: hubR*2, height: hubR*2))
hex(0x15151a).setFill(); hub.fill()
hub.lineWidth = 10; hex(0xf7f7fa).setStroke(); hub.stroke()
let dotR: CGFloat = 12
NSBezierPath(ovalIn: NSRect(x: c.x - dotR, y: c.y - dotR, width: dotR*2, height: dotR*2)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("ok: \(outPath)")
