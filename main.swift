import AppKit
import Darwin
import QuartzCore

// MARK: - MultitouchSupport C-Layouts

struct MTPoint  { var x: Float; var y: Float }
struct MTReadout { var position: MTPoint; var velocity: MTPoint }

// 96 bytes auf 64-bit, Layout 1:1 mit dem privaten Framework
struct Finger {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerNumber: Int32
    var handIndex: Int32
    var normalized: MTReadout
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTReadout
    var zero2a: Int32
    var zero2b: Int32
    var density: Float
}

typealias MTDeviceRef = UnsafeMutableRawPointer
typealias MTContactCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

// MARK: - Privates Framework via dlopen

struct MultitouchAPI {
    let create: () -> MTDeviceRef?
    let register: (MTDeviceRef, MTContactCallback) -> Void
    let start: (MTDeviceRef) -> Void
    let getDimensionsMM: (MTDeviceRef) -> (w: Float, h: Float)?
    let getFamilyID: (MTDeviceRef) -> Int32?
    let getDeviceID: (MTDeviceRef) -> UInt64?
}

func loadMultitouch() -> MultitouchAPI? {
    let paths = [
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport",
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/Current/MultitouchSupport"
    ]
    var handle: UnsafeMutableRawPointer? = nil
    for p in paths {
        handle = dlopen(p, RTLD_NOW); if handle != nil { break }
    }
    guard let h = handle else {
        if let err = dlerror() { fputs("dlopen MultitouchSupport: \(String(cString: err))\n", stderr) }
        return nil
    }

    guard let createSym = dlsym(h, "MTDeviceCreateDefault"),
          let registerSym = dlsym(h, "MTRegisterContactFrameCallback"),
          let startSym = dlsym(h, "MTDeviceStart") else {
        fputs("Konnte Pflicht-Symbole nicht laden\n", stderr); return nil
    }

    typealias CreateFn    = @convention(c) () -> MTDeviceRef?
    typealias RegisterFn  = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    typealias StartFn     = @convention(c) (MTDeviceRef, Int32) -> Void
    typealias DimsFn      = @convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    typealias FamilyFn    = @convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>) -> Int32
    typealias DeviceIDFn  = @convention(c) (MTDeviceRef, UnsafeMutablePointer<UInt64>) -> Int32

    let create   = unsafeBitCast(createSym,   to: CreateFn.self)
    let register = unsafeBitCast(registerSym, to: RegisterFn.self)
    let start    = unsafeBitCast(startSym,    to: StartFn.self)

    let dimsFn:     DimsFn?     = dlsym(h, "MTDeviceGetSensorSurfaceDimensions").map { unsafeBitCast($0, to: DimsFn.self) }
    let familyFn:   FamilyFn?   = dlsym(h, "MTDeviceGetFamilyID").map         { unsafeBitCast($0, to: FamilyFn.self) }
    let deviceIDFn: DeviceIDFn? = dlsym(h, "MTDeviceGetDeviceID").map         { unsafeBitCast($0, to: DeviceIDFn.self) }

    return MultitouchAPI(
        create: { create() },
        register: { dev, cb in register(dev, cb) },
        start:    { dev in start(dev, 0) },
        getDimensionsMM: { dev in
            guard let f = dimsFn else { return nil }
            var w: Int32 = 0, ht: Int32 = 0
            _ = f(dev, &w, &ht)
            let widthMM  = Float(w) / 100.0
            let heightMM = Float(ht) / 100.0
            guard (50...300).contains(widthMM), (30...250).contains(heightMM) else { return nil }
            return (widthMM, heightMM)
        },
        getFamilyID: { dev in
            guard let f = familyFn else { return nil }
            var fid: Int32 = 0; _ = f(dev, &fid); return fid
        },
        getDeviceID: { dev in
            guard let f = deviceIDFn else { return nil }
            var did: UInt64 = 0; _ = f(dev, &did); return did
        }
    )
}

// MARK: - Touch-Store

final class TouchStore {
    private let queue = DispatchQueue(label: "touchstore", attributes: .concurrent)
    private var _latest: [Finger] = []
    private var _frameCount: UInt64 = 0
    private var _peakSize: Float = 0
    var latest: [Finger]   { queue.sync { _latest } }
    var frameCount: UInt64 { queue.sync { _frameCount } }
    var peakSize: Float    { queue.sync { _peakSize } }
    func update(_ touches: [Finger]) {
        queue.async(flags: .barrier) {
            self._latest = touches
            self._frameCount &+= 1
            for t in touches { if t.size > self._peakSize { self._peakSize = t.size } }
        }
    }
    func resetPeak() {
        queue.async(flags: .barrier) { self._peakSize = 0 }
    }
}

// MARK: - Trail-Store (Bewegungs-Spuren pro Finger-ID)

struct TrailPoint {
    var normX: CGFloat
    var normY: CGFloat
    var size: Float
    var t: CFTimeInterval
}

final class TrailStore {
    private let queue = DispatchQueue(label: "trailstore", attributes: .concurrent)
    private var data: [Int32: [TrailPoint]] = [:]
    let lifetime: CFTimeInterval = 1.4
    let maxPoints = 80

    func update(touches: [Finger]) {
        let now = CACurrentMediaTime()
        queue.async(flags: .barrier) {
            for t in touches {
                let pt = TrailPoint(
                    normX: CGFloat(t.normalized.position.x),
                    normY: CGFloat(t.normalized.position.y),
                    size: t.size,
                    t: now
                )
                var list = self.data[t.identifier] ?? []
                if let last = list.last {
                    let dx = last.normX - pt.normX
                    let dy = last.normY - pt.normY
                    if dx*dx + dy*dy < 0.00005 && now - last.t < 0.03 { continue }
                }
                list.append(pt)
                if list.count > self.maxPoints { list.removeFirst(list.count - self.maxPoints) }
                self.data[t.identifier] = list
            }
            self.cleanupLocked(now: now)
        }
    }
    func cleanup() {
        let now = CACurrentMediaTime()
        queue.async(flags: .barrier) { self.cleanupLocked(now: now) }
    }
    private func cleanupLocked(now: CFTimeInterval) {
        let cutoff = now - lifetime
        for (k, pts) in data {
            let kept = pts.filter { $0.t > cutoff }
            if kept.isEmpty { data.removeValue(forKey: k) }
            else if kept.count != pts.count { data[k] = kept }
        }
    }
    var snapshot: [Int32: [TrailPoint]] {
        queue.sync { data }
    }
}

let touchStore = TouchStore()
let trailStore = TrailStore()
var globalView: HeatmapView?

// MARK: - Inferno Colormap

@inline(__always)
func inferno(_ t: Float) -> (UInt8, UInt8, UInt8) {
    let stops: [(Float, Float, Float, Float)] = [
        (0.00, 0.001, 0.000, 0.014),
        (0.13, 0.107, 0.044, 0.273),
        (0.25, 0.258, 0.039, 0.406),
        (0.38, 0.423, 0.085, 0.435),
        (0.50, 0.582, 0.149, 0.404),
        (0.63, 0.736, 0.216, 0.330),
        (0.75, 0.873, 0.319, 0.227),
        (0.88, 0.967, 0.480, 0.109),
        (0.96, 0.988, 0.722, 0.072),
        (1.00, 0.988, 0.998, 0.645)
    ]
    let v = max(0, min(0.9999, t))
    for i in 0..<(stops.count - 1) {
        let s0 = stops[i], s1 = stops[i+1]
        if v >= s0.0 && v < s1.0 {
            let f = (v - s0.0) / (s1.0 - s0.0)
            return (UInt8((s0.1 + (s1.1 - s0.1) * f) * 255),
                    UInt8((s0.2 + (s1.2 - s0.2) * f) * 255),
                    UInt8((s0.3 + (s1.3 - s0.3) * f) * 255))
        }
    }
    return (252, 254, 164)
}

@inline(__always)
func infernoCG(_ t: Float, alpha: CGFloat = 1) -> CGColor {
    let (r, g, b) = inferno(t)
    return CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: alpha)
}

// MARK: - Touch-State Strings

func stateString(_ s: Int32) -> String {
    switch s {
    case 0: return "—"
    case 1: return "MAKE"
    case 2: return "HOVER"
    case 3: return "BEGIN"
    case 4: return "TOUCH"
    case 5: return "HOLD"
    case 6: return "BRK"
    case 7: return "OUT"
    default: return "?\(s)"
    }
}

func stateColor(_ s: Int32) -> NSColor {
    switch s {
    case 1, 3:    return NSColor(red: 0.4, green: 0.95, blue: 0.6, alpha: 1) // green = starting
    case 4, 5:    return NSColor(red: 0.4, green: 0.85, blue: 1.0, alpha: 1) // blue = active
    case 6, 7:    return NSColor(red: 1.0, green: 0.55, blue: 0.45, alpha: 1) // red = leaving
    default:      return NSColor(white: 0.7, alpha: 1)
    }
}

// MARK: - Heatmap-View

final class HeatmapView: NSView {

    var trackpadWidthMM:  Float = 160
    var trackpadHeightMM: Float = 110
    var deviceInfo: String = ""

    // Wird in setupGrid() berechnet — Default 64 Zellen (~2.5mm/Zelle)
    private var gridW: Int = 64
    private var gridH: Int = 40

    private var instant: [Float] = []
    private var persistent: [Float] = []

    private var displayLink: CVDisplayLink?
    private let sidePanelWidth: CGFloat = 240

    // Winkel-Konvention durchschaltbar mit 'A'-Taste
    // Default: -rad mirror (Mode 7) — korrekte Richtung und Orientierung
    private var angleMode: Int = 7
    private let angleModeCount = 8
    private func angleModeLabel(_ m: Int) -> String {
        switch m {
        case 0: return "rad, 0=ost"
        case 1: return "deg-90, 0=nord"
        case 2: return "deg, 0=ost"
        case 3: return "rad-90, 0=nord"
        case 4: return "-deg+90, mirror"
        case 5: return "-deg, mirror"
        case 6: return "-rad+90, mirror"
        case 7: return "-rad, mirror"
        default: return "?"
        }
    }
    private func angleRadFromMT(_ a: Float) -> Float {
        switch angleMode {
        case 0: return a
        case 1: return (a - 90.0) * .pi / 180.0
        case 2: return a * .pi / 180.0
        case 3: return a - .pi / 2
        case 4: return -(a - 90.0) * .pi / 180.0
        case 5: return -a * .pi / 180.0
        case 6: return -a + .pi / 2
        case 7: return -a
        default: return a
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.035, alpha: 1).cgColor
        setupGrid()
        startDisplayLink()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let link = displayLink { CVDisplayLinkStop(link) }
    }

    func configureTrackpad(widthMM: Float, heightMM: Float) {
        trackpadWidthMM = widthMM
        trackpadHeightMM = heightMM
        setupGrid()
    }

    // Nur die Buffer (re-)allokieren bei aktuellen gridW/gridH
    private func resetGridArrays() {
        instant = Array(repeating: 0, count: gridW * gridH)
        persistent = Array(repeating: 0, count: gridW * gridH)
    }

    // gridH automatisch ans Trackpad-Aspect-Ratio anpassen
    private func setupGrid() {
        let aspect = trackpadWidthMM / trackpadHeightMM
        gridH = max(8, Int(Float(gridW) / aspect))
        resetGridArrays()
    }

    private func adjustGridX(by delta: Int) {
        let newW = min(200, max(12, gridW + delta))
        if newW == gridW { return }
        gridW = newW
        resetGridArrays()
        needsDisplay = true
    }

    private func adjustGridY(by delta: Int) {
        let newH = min(160, max(8, gridH + delta))
        if newH == gridH { return }
        gridH = newH
        resetGridArrays()
        needsDisplay = true
    }

    // MARK: DisplayLink

    private func startDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link = link else { return }
        displayLink = link
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, _ in
            DispatchQueue.main.async {
                if let v = globalView {
                    v.tick()
                }
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, nil)
        CVDisplayLinkStart(link)
    }

    private func tick() {
        // Decay des Persistence-Buffers (langsam → "Abdruck" bleibt länger sichtbar)
        let decay: Float = 0.992
        for i in persistent.indices { persistent[i] *= decay }
        trailStore.cleanup()
        needsDisplay = true
    }

    // MARK: Layout

    private func computeTrackpadRect() -> CGRect {
        let padX: CGFloat = 22
        let padTop: CGFloat = 42
        let padBottom: CGFloat = 50
        let availW = bounds.width  - 2 * padX - sidePanelWidth - 16
        let availH = bounds.height - padTop - padBottom
        let aspect = CGFloat(trackpadWidthMM) / CGFloat(trackpadHeightMM)
        var rectW = availW
        var rectH = rectW / aspect
        if rectH > availH {
            rectH = availH
            rectW = rectH * aspect
        }
        let originX = padX + (availW - rectW) / 2
        let originY = padTop + (availH - rectH) / 2
        return CGRect(x: originX, y: originY, width: rectW, height: rectH)
    }

    private func mapNorm(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width,
                y: rect.minY + (1.0 - y) * rect.height)
    }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let touches = touchStore.latest
        let tpRect = computeTrackpadRect()

        // 1) Hintergrund
        ctx.setFillColor(NSColor(white: 0.035, alpha: 1).cgColor)
        ctx.fill(bounds)

        // 2) Sensor-Field berechnen
        computeField(touches: touches)

        // 3) Heatmap zeichnen
        drawHeatmap(ctx: ctx, rect: tpRect)

        // 4) Subtiles Zell-Gitter
        drawCellGrid(ctx: ctx, rect: tpRect)

        // 5) Trackpad-Outline + Ecken
        drawTrackpadFrame(ctx: ctx, rect: tpRect)

        // 6) mm-Skala (Tick-Marks)
        drawTickMarks(ctx: ctx, rect: tpRect)

        // 8) Pro-Finger Overlays (Ellipse-Outline, Center, Label)
        drawContacts(ctx: ctx, rect: tpRect, touches: touches)

        // 9) Side-Panel
        let panelRect = CGRect(
            x: tpRect.maxX + 16,
            y: tpRect.minY,
            width: sidePanelWidth,
            height: tpRect.height
        )
        drawSidePanel(ctx: ctx, rect: panelRect, touches: touches)

        // 10) HUD (oben + unten)
        drawHUD(ctx: ctx, tpRect: tpRect, touches: touches)
    }

    // MARK: Field Computation (2D-Gauß-Splats)

    private func computeField(touches: [Finger]) {
        for i in instant.indices { instant[i] = 0 }
        let mmToCellX = Float(gridW) / trackpadWidthMM
        let mmToCellY = Float(gridH) / trackpadHeightMM

        for t in touches {
            let cx = Float(t.normalized.position.x) * Float(gridW)
            let cy = (1.0 - Float(t.normalized.position.y)) * Float(gridH)

            // Ellipse-Semi-Achsen in Zell-Koordinaten
            // majorAxis/minorAxis sind in mm; * 0.5 für Semi-Achse, dann Boost für sichtbarere Größe
            let a = max(t.majorAxis * mmToCellX * 0.7, 1.4)  // semi-major in cells
            let b = max(t.minorAxis * mmToCellY * 0.7, 1.0)  // semi-minor in cells

            let angleRad = angleRadFromMT(t.angle)
            let ca = cosf(angleRad)
            let sa = sinf(angleRad)

            let pressure = max(t.size, t.density)
            // Pressure-Boost moderat: 0.85..1.4
            let pBoost = min(pressure * 0.25 + 0.85, 1.4)

            // Bounding box: Halo bis ~1.8x der Ellipse
            let bound = Int(ceil(max(a, b) * 2.0))
            let cxi = Int(cx), cyi = Int(cy)
            let x0 = max(0, cxi - bound), x1 = min(gridW - 1, cxi + bound)
            let y0 = max(0, cyi - bound), y1 = min(gridH - 1, cyi + bound)
            if x0 > x1 || y0 > y1 { continue }

            let invA2 = 1.0 / (a * a)
            let invB2 = 1.0 / (b * b)

            // Sub-Sampling: 4x4 = 16 Samples pro Zelle für sauberes Anti-Aliasing
            let sub = 4
            let subStep: Float = 1.0 / Float(sub)
            let subOffset: Float = subStep * 0.5

            for y in y0...y1 {
                let rowBase = y * gridW
                for x in x0...x1 {
                    var insideCount = 0
                    var minD2: Float = .infinity

                    for sy in 0..<sub {
                        let fy = Float(y) + Float(sy) * subStep + subOffset
                        let dy = fy - cy
                        for sx in 0..<sub {
                            let fx = Float(x) + Float(sx) * subStep + subOffset
                            let dx = fx - cx
                            let rx = ca * dx + sa * dy
                            let ry = -sa * dx + ca * dy
                            let d2 = rx*rx * invA2 + ry*ry * invB2
                            if d2 < 1.0 { insideCount += 1 }
                            if d2 < minD2 { minD2 = d2 }
                        }
                    }

                    let coverage = Float(insideCount) / Float(sub * sub)

                    // Diskrete Intensitäts-Level:
                    //   2.0+  → SPECIAL (100% bedeckt)
                    //   1.0..1.99 → strong
                    //   0.6..1.0  → mid
                    //   0.3..0.6  → edge
                    //   0.05..0.3 → halo
                    //   0         → leer
                    var value: Float = 0
                    if coverage >= 0.999 {
                        value = 2.0 * pBoost  // 100% bedeckt → accent
                    } else if coverage > 0 {
                        // Lineares Mapping inside-ellipse (≥1.0 nicht erreichen außer bei full)
                        value = (0.4 + 0.55 * coverage) * pBoost
                    } else if minD2 < 2.5 {
                        // Halo: außerhalb der Ellipse aber in der Nähe
                        let h = max(0, 1.0 - (minD2 - 1.0) / 1.5)
                        value = 0.22 * h * pBoost
                    }

                    if value > instant[rowBase + x] {
                        instant[rowBase + x] = value
                    }
                }
            }
        }

        // Persistence: Max-Blend
        for i in instant.indices {
            if instant[i] > persistent[i] { persistent[i] = instant[i] }
        }
    }

    private func drawHeatmap(ctx: CGContext, rect: CGRect) {
        var pixels = [UInt8](repeating: 0, count: gridW * gridH * 4)
        for i in 0..<(gridW * gridH) {
            let v = instant[i] + persistent[i] * 0.30

            // Diskrete Farbtreppe — jede Stufe ein klarer Farbsprung
            let rr: UInt8, gg: UInt8, bb: UInt8
            if v >= 1.8 {
                // 100% BEDECKT — Accent: Cyan-Weiß (sticht klar aus Inferno raus)
                rr = 190; gg = 245; bb = 255
            } else if v >= 1.2 {
                // Strong: weiß-gelb
                rr = 252; gg = 230; bb = 130
            } else if v >= 0.85 {
                // Mid-Strong: orange
                rr = 248; gg = 145; bb = 40
            } else if v >= 0.55 {
                // Mid: rot
                rr = 220; gg = 60; bb = 70
            } else if v >= 0.35 {
                // Edge: dunkelrot
                rr = 150; gg = 30; bb = 80
            } else if v >= 0.15 {
                // Halo: dunkel-lila
                rr = 60; gg = 15; bb = 70
            } else if v >= 0.04 {
                // Far halo: nur Hauch
                rr = 25; gg = 10; bb = 35
            } else {
                // Leere Zelle: dunkel-grau (sichtbar als LED-aus)
                rr = 14; gg = 15; bb = 22
            }

            pixels[i*4+0] = rr; pixels[i*4+1] = gg; pixels[i*4+2] = bb; pixels[i*4+3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bm = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let data = Data(bytes: pixels, count: pixels.count)
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(
                  width: gridW, height: gridH,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: gridW * 4,
                  space: cs, bitmapInfo: bm,
                  provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent
              ) else { return }

        ctx.saveGState()
        ctx.interpolationQuality = .none
        // Flipped-Koord-System: manuell flippen für CGImage
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private func drawCellGrid(ctx: CGContext, rect: CGRect) {
        // Jede Zelle als deutlich sichtbares LED-Feld
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.55).cgColor)
        ctx.setLineWidth(0.8)
        let cellW = rect.width  / CGFloat(gridW)
        let cellH = rect.height / CGFloat(gridH)
        for i in 0...gridW {
            let x = rect.minX + CGFloat(i) * cellW
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for j in 0...gridH {
            let y = rect.minY + CGFloat(j) * cellH
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        ctx.strokePath()
    }

    private func drawTrackpadFrame(ctx: CGContext, rect: CGRect) {
        // Outline (rounded rect) — nur noch dezente graue Linie
        ctx.setStrokeColor(NSColor(white: 0.42, alpha: 1).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.strokePath()
    }

    private func drawTickMarks(ctx: CGContext, rect: CGRect) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.6, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        ]
        ctx.setStrokeColor(NSColor(white: 0.5, alpha: 1).cgColor)

        let pxPerMM_X = rect.width  / CGFloat(trackpadWidthMM)

        // Bottom: jede 10mm Tick, jede 50mm Label
        for mm in stride(from: 0, through: Int(trackpadWidthMM), by: 10) {
            let x = rect.minX + CGFloat(mm) * pxPerMM_X
            let major = (mm % 50 == 0)
            ctx.setLineWidth(major ? 1.0 : 0.5)
            ctx.move(to: CGPoint(x: x, y: rect.maxY + 10))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY + 10 + (major ? 6 : 3)))
            ctx.strokePath()
            if major && mm > 0 && mm < Int(trackpadWidthMM) {
                ("\(mm)" as NSString).draw(
                    at: NSPoint(x: x - 7, y: rect.maxY + 18),
                    withAttributes: labelAttrs)
            }
        }
        // Right: jede 10mm Tick, jede 50mm Label
        for mm in stride(from: 0, through: Int(trackpadHeightMM), by: 10) {
            let y = rect.minY + (1 - CGFloat(mm) / CGFloat(trackpadHeightMM)) * rect.height
            let major = (mm % 50 == 0)
            ctx.setLineWidth(major ? 1.0 : 0.5)
            ctx.move(to: CGPoint(x: rect.maxX + 10, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX + 10 + (major ? 6 : 3), y: y))
            ctx.strokePath()
            if major && mm > 0 && mm < Int(trackpadHeightMM) {
                ("\(mm)" as NSString).draw(
                    at: NSPoint(x: rect.maxX + 18, y: y - 5),
                    withAttributes: labelAttrs)
            }
        }
        // Unit-Label
        ("mm" as NSString).draw(
            at: NSPoint(x: rect.maxX - 16, y: rect.maxY + 18),
            withAttributes: labelAttrs
        )
    }

    private func drawTrails(ctx: CGContext, rect: CGRect) {
        let trails = trailStore.snapshot
        let now = CACurrentMediaTime()
        for (_, points) in trails where points.count > 1 {
            // Linie als Pfad zeichnen, jede Segment-Alpha basierend auf Alter
            for i in 1..<points.count {
                let p0 = points[i-1]
                let p1 = points[i]
                let age = now - p1.t
                let a = max(0, 1.0 - age / trailStore.lifetime)
                if a < 0.05 { continue }
                let v0 = mapNorm(p0.normX, p0.normY, in: rect)
                let v1 = mapNorm(p1.normX, p1.normY, in: rect)
                ctx.setStrokeColor(NSColor(red: 0.45, green: 0.92, blue: 1.0, alpha: CGFloat(a) * 0.75).cgColor)
                ctx.setLineWidth(1.6)
                ctx.move(to: v0)
                ctx.addLine(to: v1)
                ctx.strokePath()
            }
        }
    }

    private func drawContacts(ctx: CGContext, rect: CGRect, touches: [Finger]) {
        let pxPerMM_X = rect.width  / CGFloat(trackpadWidthMM)
        let pxPerMM_Y = rect.height / CGFloat(trackpadHeightMM)

        for t in touches {
            let center = mapNorm(CGFloat(t.normalized.position.x),
                                 CGFloat(t.normalized.position.y), in: rect)
            let majorPts = CGFloat(t.majorAxis) * pxPerMM_X
            let minorPts = CGFloat(t.minorAxis) * pxPerMM_Y
            let angleRad = CGFloat(angleRadFromMT(t.angle))

            // Ellipse-Outline
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: angleRad)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(
                x: -majorPts/2, y: -minorPts/2,
                width: majorPts, height: minorPts))
            // Major-Achse als Linie
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.2)
            ctx.move(to: CGPoint(x: -majorPts/2, y: 0))
            ctx.addLine(to: CGPoint(x: majorPts/2, y: 0))
            ctx.strokePath()
            ctx.restoreGState()

            // Center-Crosshair (weiß)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: center.x - 4, y: center.y))
            ctx.addLine(to: CGPoint(x: center.x + 4, y: center.y))
            ctx.move(to: CGPoint(x: center.x, y: center.y - 4))
            ctx.addLine(to: CGPoint(x: center.x, y: center.y + 4))
            ctx.strokePath()

            // ID-Label (einheitlich weiß)
            let label = String(format: "#%d", t.identifier) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
            ]
            let halo: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.black.withAlphaComponent(0.85),
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
            ]
            let labelPos = NSPoint(x: center.x + 6, y: center.y - 14)
            for dx in [-1, 0, 1] {
                for dy in [-1, 0, 1] where dx != 0 || dy != 0 {
                    label.draw(at: NSPoint(x: labelPos.x + CGFloat(dx), y: labelPos.y + CGFloat(dy)),
                               withAttributes: halo)
                }
            }
            label.draw(at: labelPos, withAttributes: attrs)
        }
    }

    private func drawSidePanel(ctx: CGContext, rect: CGRect, touches: [Finger]) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.9, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        ]
        let smallMono: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.85, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        ]
        let dimMono: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.5, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        ]
        let labelMono: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.6, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        ]

        // Header
        ("CONTACTS  (\(touches.count))" as NSString).draw(
            at: NSPoint(x: rect.minX, y: rect.minY),
            withAttributes: titleAttrs)

        var y = rect.minY + 20
        let cardH: CGFloat = 84

        if touches.isEmpty {
            let hint = "— Trackpad berühren —" as NSString
            hint.draw(at: NSPoint(x: rect.minX, y: y + 8), withAttributes: dimMono)
        }

        for t in touches {
            if y + cardH > rect.maxY - 20 { break }
            let card = CGRect(x: rect.minX, y: y, width: rect.width, height: cardH)

            // Card BG
            ctx.setFillColor(NSColor(white: 0.10, alpha: 0.85).cgColor)
            ctx.addPath(CGPath(roundedRect: card, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            ctx.setStrokeColor(NSColor(white: 0.22, alpha: 1).cgColor)
            ctx.setLineWidth(0.5)
            ctx.stroke(card)

            // Druck-Badge (Farbe = Inferno bei size/4)
            let badgeRect = CGRect(x: card.minX + 7, y: card.minY + 7, width: 12, height: 12)
            ctx.setFillColor(infernoCG(min(t.size / 4.0, 0.99)))
            ctx.fillEllipse(in: badgeRect)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokeEllipse(in: badgeRect)

            // ID + State
            (String(format: "#%d", t.identifier) as NSString).draw(
                at: NSPoint(x: card.minX + 26, y: card.minY + 6),
                withAttributes: titleAttrs)
            let st = stateString(t.state) as NSString
            let stAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: stateColor(t.state),
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
            ]
            st.draw(at: NSPoint(x: card.minX + 64, y: card.minY + 7), withAttributes: stAttrs)

            // Daten in 2 Spalten
            let colA = card.minX + 8
            let colB = card.minX + 122
            var ly = card.minY + 24
            let lineH: CGFloat = 11

            let px = t.absolute.position.x
            let py = t.absolute.position.y
            let vx = t.absolute.velocity.x
            let vy = t.absolute.velocity.y
            let vMag = sqrt(vx*vx + vy*vy)

            ("pos" as NSString).draw(at: NSPoint(x: colA, y: ly), withAttributes: labelMono)
            (String(format: "%5.1f, %5.1f mm", px, py) as NSString).draw(
                at: NSPoint(x: colA + 22, y: ly), withAttributes: smallMono)
            ly += lineH

            ("size" as NSString).draw(at: NSPoint(x: colA, y: ly), withAttributes: labelMono)
            (String(format: "%5.2f", t.size) as NSString).draw(
                at: NSPoint(x: colA + 26, y: ly), withAttributes: smallMono)

            ("dens" as NSString).draw(at: NSPoint(x: colB, y: ly), withAttributes: labelMono)
            (String(format: "%5.2f", t.density) as NSString).draw(
                at: NSPoint(x: colB + 28, y: ly), withAttributes: smallMono)
            ly += lineH

            ("axes" as NSString).draw(at: NSPoint(x: colA, y: ly), withAttributes: labelMono)
            (String(format: "%4.1f × %4.1f mm", t.majorAxis, t.minorAxis) as NSString).draw(
                at: NSPoint(x: colA + 26, y: ly), withAttributes: smallMono)
            ly += lineH

            ("ang" as NSString).draw(at: NSPoint(x: colA, y: ly), withAttributes: labelMono)
            (String(format: "%5.1f°", t.angle) as NSString).draw(
                at: NSPoint(x: colA + 22, y: ly), withAttributes: smallMono)

            ("vel" as NSString).draw(at: NSPoint(x: colB, y: ly), withAttributes: labelMono)
            (String(format: "%5.1f mm/s", vMag) as NSString).draw(
                at: NSPoint(x: colB + 22, y: ly), withAttributes: smallMono)

            y += cardH + 6
        }
    }

    private func drawHUD(ctx: CGContext, tpRect: CGRect, touches: [Finger]) {
        let hudAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.88, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        ]
        let dim: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.55, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        ]

        // Top-Title
        ("TRACKPAD HEATMAP" as NSString).draw(
            at: NSPoint(x: 16, y: 12), withAttributes: hudAttrs)

        let cellMMx = trackpadWidthMM  / Float(gridW)
        let cellMMy = trackpadHeightMM / Float(gridH)
        let info = String(
            format: "%@  ·  %.0f × %.0f mm  ·  %d × %d cells (%.2f × %.2f mm)  ·  frame %llu  ·  peak %.2f",
            deviceInfo, trackpadWidthMM, trackpadHeightMM,
            gridW, gridH, cellMMx, cellMMy,
            touchStore.frameCount, touchStore.peakSize
        ) as NSString
        info.draw(at: NSPoint(x: 16, y: 27), withAttributes: dim)

        // Angle-Mode prominent rechts oben
        let modeStr = String(format: "ANGLE MODE %d/%d  ·  %@  ·  [A] next  [Q] prev",
                             angleMode, angleModeCount - 1, angleModeLabel(angleMode)) as NSString
        let modeAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(red: 0.5, green: 0.95, blue: 1.0, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        ]
        let size = modeStr.size(withAttributes: modeAttrs)
        modeStr.draw(at: NSPoint(x: bounds.width - size.width - 16, y: 12),
                     withAttributes: modeAttrs)

        // Beispiel-Roh-Winkel (erster Touch), damit man sieht ob die Daten ankommen
        if let first = touches.first {
            let raw = String(format: "raw angle = %.3f  ·  axes %.1f × %.1f",
                             first.angle, first.majorAxis, first.minorAxis) as NSString
            raw.draw(at: NSPoint(x: bounds.width - size.width - 16, y: 27),
                     withAttributes: dim)
        }

        // Bottom-Colorbar
        let cbW: CGFloat = 220
        let cbRect = CGRect(x: tpRect.minX, y: bounds.height - 22, width: cbW, height: 8)
        drawColorbar(ctx: ctx, rect: cbRect)
        ("druck →" as NSString).draw(
            at: NSPoint(x: cbRect.minX, y: cbRect.maxY + 1),
            withAttributes: dim)
        ("0" as NSString).draw(at: NSPoint(x: cbRect.minX, y: cbRect.minY - 11), withAttributes: dim)
        ("max" as NSString).draw(at: NSPoint(x: cbRect.maxX - 18, y: cbRect.minY - 11), withAttributes: dim)

        // Tasten-Hinweise rechts unten
        let keys = "← → X-Zellen   ↑ ↓ Y-Zellen   C: aspect   A/Q: angle   ESC: beenden" as NSString
        let keysSize = keys.size(withAttributes: dim)
        keys.draw(
            at: NSPoint(x: bounds.width - keysSize.width - 16, y: bounds.height - 20),
            withAttributes: dim)
    }

    private func drawColorbar(ctx: CGContext, rect: CGRect) {
        // Diskrete Stufen passend zum neuen Renderer
        let stops: [(CGFloat, CGFloat, CGFloat, String)] = [
            (14/255,  15/255,  22/255, "leer"),
            (60/255,  15/255,  70/255, "halo"),
            (150/255, 30/255,  80/255, "edge"),
            (220/255, 60/255,  70/255, "mid"),
            (248/255, 145/255, 40/255, "strong"),
            (252/255, 230/255, 130/255, "high"),
            (190/255, 245/255, 255/255, "100%"),
        ]
        let stepW = rect.width / CGFloat(stops.count)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.65, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        ]
        for (i, s) in stops.enumerated() {
            ctx.setFillColor(red: s.0, green: s.1, blue: s.2, alpha: 1)
            let r = CGRect(x: rect.minX + CGFloat(i) * stepW, y: rect.minY,
                           width: stepW, height: rect.height)
            ctx.fill(r)
            (s.3 as NSString).draw(at: NSPoint(x: r.minX + 2, y: rect.minY - 11),
                                   withAttributes: labelAttrs)
        }
        ctx.setStrokeColor(NSColor(white: 0.4, alpha: 1).cgColor)
        ctx.setLineWidth(0.5)
        ctx.stroke(rect)
    }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: NSApp.terminate(nil)                  // ESC
        case 15: touchStore.resetPeak()                // 'R'
        case 0:                                          // 'A' — angle mode vor
            angleMode = (angleMode + 1) % angleModeCount
            for i in persistent.indices { persistent[i] = 0 }
            needsDisplay = true
        case 12:                                         // 'Q' — angle mode zurück
            angleMode = (angleMode + angleModeCount - 1) % angleModeCount
            for i in persistent.indices { persistent[i] = 0 }
            needsDisplay = true
        case 124: adjustGridX(by:  4)                  // → mehr X-Zellen
        case 123: adjustGridX(by: -4)                  // ← weniger X-Zellen
        case 126: adjustGridY(by:  4)                  // ↑ mehr Y-Zellen
        case 125: adjustGridY(by: -4)                  // ↓ weniger Y-Zellen
        case 8:                                          // 'C' — zurück auf Aspect
            setupGrid()
            needsDisplay = true
        default: break
        }
    }
}

// MARK: - Callback

let contactCallback: MTContactCallback = { _, rawFingers, count, _, _ in
    var arr: [Finger] = []
    arr.reserveCapacity(Int(count))
    if let raw = rawFingers {
        let typed = raw.bindMemory(to: Finger.self, capacity: Int(count))
        for i in 0..<Int(count) { arr.append(typed[i]) }
    }
    touchStore.update(arr)
    trailStore.update(touches: arr)
    return 0
}

// MARK: - App-Setup

let app = NSApplication.shared
app.setActivationPolicy(.regular)

guard let mt = loadMultitouch() else {
    fputs("MultitouchSupport konnte nicht geladen werden.\n", stderr); exit(1)
}
guard let device = mt.create() else {
    fputs("Kein Multitouch-Gerät gefunden.\n", stderr); exit(1)
}

let window = NSWindow(
    contentRect: NSRect(x: 80, y: 80, width: 1200, height: 720),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "Trackpad Heatmap — Detail Mode"
window.minSize = NSSize(width: 900, height: 560)

let view = HeatmapView(frame: window.contentView!.bounds)
view.autoresizingMask = [.width, .height]

// Echte Trackpad-Maße auslesen
if let dims = mt.getDimensionsMM(device) {
    view.configureTrackpad(widthMM: dims.w, heightMM: dims.h)
    fputs("Trackpad: \(dims.w) × \(dims.h) mm\n", stderr)
} else {
    fputs("Verwende Default-Maße (160 × 110 mm)\n", stderr)
}

// Device-Info
var infoParts: [String] = []
if let fid = mt.getFamilyID(device) { infoParts.append("family \(fid)") }
if let did = mt.getDeviceID(device) { infoParts.append(String(format: "id 0x%llx", did)) }
view.deviceInfo = infoParts.isEmpty ? "trackpad" : infoParts.joined(separator: "  ·  ")

window.contentView = view
globalView = view
window.makeFirstResponder(view)
window.makeKeyAndOrderFront(nil)

mt.register(device, contactCallback)
mt.start(device)

app.activate(ignoringOtherApps: true)
app.run()
