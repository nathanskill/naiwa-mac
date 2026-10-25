// 奶蛙 Mac 版 —— 照 Windows「奶蛙极致版 3.0」（github.com/22hewang/naiwa-ultimate）的玩法重写。
// 素材（走 / 跑 / 笑三套帧、笑声、爆炸声）取自原版发布包，版权归原作者。
// 和原版一样按 PolyForm Noncommercial 1.0.0 发布（见 LICENSE），禁止商用。
//
// 玩法和原版一样：
//   - 每隔一段时间从屏幕左右边缘跑进来一只，可以同时有很多只
//   - 鼠标慢慢挪过去它不太察觉；快速靠近或贴得太近，它会加速逃跑
//   - 左键点中 = 抓到：原地爆笑 → 躺平 → 放烟花消失，已抓 +1
//   - 跑出屏幕左右边缘 = 逃走
//   - 控制条：召唤 1/10/100/999/自定义、仙乐（全场一起笑）、瞬爆（全场放烟花）、清屏、退出（原版叫「开溜」，容易误点，改成直说）
//   - 热键：⌃⌥Q 退出，⌃⌥N 召唤一只，⌃⌥P 显示/收起控制条
//
// 窗口是一整块透明、置顶、鼠标穿透的覆盖层；只有鼠标正好压在奶蛙身上时才接点击，
// 其余地方点击直接落到下面的桌面和其他程序。

import AppKit
import SpriteKit
import AVFoundation
import Carbon.HIToolbox

// MARK: - 手感常量（数值与原版 naowa.py 一致，距离单位是点）

let D_FAR: CGFloat = 520
let D_RUN: CGFloat = 200
let D_NEAR: CGFloat = 45
let WALK_K: CGFloat = 0.84
let WALK_MAX_K: CGFloat = 1.1
let RUN_MAX_K: CGFloat = 2.72
let ENTER_K: CGFloat = 2.2
let WALK_STRIDE_K: CGFloat = 0.66
let RUN_STRIDE_K: CGFloat = 1.52
let RUN_START_K: CGFloat = 1.44
let D_RUN_ON: CGFloat = 145
let D_RUN_OFF: CGFloat = 210
let MODE_HOLD = 1.0
let ALERT_K: CGFloat = 1.04
let PANIC_K: CGFloat = 0.464
let CALM_K: CGFloat = 2.4
let CURSOR_SPEED_LIMIT: CGFloat = 420
let REACT_DELAY = 0.14
let N_FRAMES = 8
let LAUGH_FPS = 15.0
let LAUGH_LIE_FRAME = 124      // 躺平那一帧：到这里就收声
let BURST_HOLD = 0.45
let MAX_PETS = 9999
let BOOM_MAX_LIVE = 160        // 同时存在的烟花上限，超出的只做一个小闪光
let HIT_ALPHA: UInt8 = 120     // 低于这个透明度的像素（脚下影子）点了不算

let INTERVALS: [(Double, String)] = [(0, "不自动"), (10, "10 秒"), (15, "15 秒"), (30, "30 秒"),
                                     (60, "1 分钟"), (120, "2 分钟"), (180, "3 分钟"), (300, "5 分钟")]
let SIZES: [(CGFloat, String)] = [(80, "小"), (115, "中"), (160, "大")]
let COUNTS = [1, 10, 100, 999]
let PALETTE: [NSColor] = [
    NSColor(srgbRed: 1.00, green: 0.36, blue: 0.52, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.80, blue: 0.20, alpha: 1),
    NSColor(srgbRed: 0.30, green: 0.85, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.55, green: 1.00, blue: 0.40, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.55, blue: 0.15, alpha: 1),
    NSColor(srgbRed: 0.75, green: 0.50, blue: 1.00, alpha: 1),
]

func rnd(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b) }

/// 只记启动、点中、退出这几件事，排查「怎么没了」用：~/Library/Logs/奶蛙.log
func naiwaLog(_ s: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/奶蛙.log")
    let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(s)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line)
        try? h.close()
    } else {
        try? line.write(to: url)
    }
}

// MARK: - 素材

final class Assets {
    static let shared = Assets()
    let fw = 110, fh = 158
    var walk: [SKTexture] = [], run: [SKTexture] = [], laugh: [SKTexture] = []
    var walkMask: [[UInt8]] = [], runMask: [[UInt8]] = [], laughMask: [[UInt8]] = []
    var laughWav = Data(), boomWav = Data()
    var spark: SKTexture!
    var menuIcon: NSImage?

    func load() {
        guard let res = Bundle.main.resourceURL else { return }
        let dir = res.appendingPathComponent("frames")
        var images: [String: NSImage] = [:]
        func loadSet(_ prefix: String) -> ([String], [[UInt8]]) {
            var names: [String] = [], masks: [[UInt8]] = []
            var i = 0
            while true {
                let name = String(format: "%@_%03d", prefix, i)
                guard let img = NSImage(contentsOf: dir.appendingPathComponent(name + ".png")),
                      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { break }
                images[name] = img
                names.append(name)
                masks.append(alphaMask(cg))
                i += 1
            }
            return (names, masks)
        }
        let (w, wm) = loadSet("walk"), (r, rm) = loadSet("run"), (l, lm) = loadSet("laugh")
        // 全部帧放进一张图集，几千只同屏时 SpriteKit 能合批绘制
        let atlas = SKTextureAtlas(dictionary: images)
        walk = w.map { atlas.textureNamed($0) }
        run = r.map { atlas.textureNamed($0) }
        laugh = l.map { atlas.textureNamed($0) }
        walkMask = wm; runMask = rm; laughMask = lm
        laughWav = (try? Data(contentsOf: res.appendingPathComponent("sounds/laugh.wav"))) ?? Data()
        boomWav = (try? Data(contentsOf: res.appendingPathComponent("sounds/boom.wav"))) ?? Data()
        spark = SKTexture(image: makeSpark())
        if let icon = NSImage(contentsOf: res.appendingPathComponent("menu_icon.png")) {
            let h: CGFloat = 18
            icon.size = NSSize(width: icon.size.width * h / icon.size.height, height: h)
            menuIcon = icon
        }
    }

    /// 每帧的 alpha 表（第 0 行是图片最上面一行），用来判断鼠标是不是压在奶蛙身上。
    func alphaMask(_ cg: CGImage) -> [UInt8] {
        let n = fw * fh
        var rgba = [UInt8](repeating: 0, count: n * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: fw, height: fh, bitsPerComponent: 8,
                                      bytesPerRow: fw * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: fw, height: fh))
            return true
        }
        guard ok else { return [UInt8](repeating: 255, count: n) }
        var a = [UInt8](repeating: 0, count: n)
        for i in 0..<n { a[i] = rgba[i * 4 + 3] }
        return a
    }

    func makeSpark() -> NSImage {
        let s: CGFloat = 32
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        let g = NSGradient(colors: [.white, NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0)],
                           atLocations: [0, 0.3, 1], colorSpace: .deviceRGB)
        g?.draw(in: NSRect(x: 0, y: 0, width: s, height: s), relativeCenterPosition: .zero)
        img.unlockFocus()
        return img
    }
}

let A = Assets.shared

// MARK: - 声音

/// 笑声和爆炸声各一小池播放器。几千只一起笑时只放得下前几层，再多也听不出区别。
final class Sound {
    var enabled = true
    private var laughs: [AVAudioPlayer] = []
    private var laughOwner: [Int] = []
    private var booms: [AVAudioPlayer] = []
    private var lastBoom = -1.0

    init(laugh: Data, boom: Data) {
        for _ in 0..<12 {
            if let p = try? AVAudioPlayer(data: laugh) { p.volume = 0.7; p.prepareToPlay(); laughs.append(p); laughOwner.append(0) }
        }
        for _ in 0..<6 {
            if let p = try? AVAudioPlayer(data: boom) { p.volume = 0.8; p.prepareToPlay(); booms.append(p) }
        }
    }

    func laugh(owner: Int) -> Int? {
        guard enabled else { return nil }
        for (i, p) in laughs.enumerated() where !p.isPlaying {
            laughOwner[i] = owner
            p.currentTime = 0
            p.play()
            return i
        }
        return nil
    }

    /// 只停自己那一层：播放器可能已经被下一只拿去用了。
    func stopLaugh(_ i: Int, owner: Int) {
        guard i < laughs.count, laughOwner[i] == owner else { return }
        laughs[i].stop()
        laughOwner[i] = 0
    }

    func boom(now: Double, minGap: Double) {
        guard enabled, now - lastBoom >= minGap else { return }
        if let p = booms.first(where: { !$0.isPlaying }) {
            lastBoom = now
            p.currentTime = 0
            p.play()
        }
    }

    func stopAll() {
        laughs.forEach { $0.stop() }
        booms.forEach { $0.stop() }
        for i in laughOwner.indices { laughOwner[i] = 0 }
    }
}

// MARK: - 奶蛙

enum PetState { case enter, idle, flee, caught }
enum PetMode { case walk, run }

final class Pet {
    static var nextID = 1
    let id: Int
    let node = SKSpriteNode()
    var x: CGFloat, y: CGFloat            // 中心点，场景坐标（左下角为原点）
    var vx: CGFloat, vy: CGFloat          // 单位方向
    var speed: CGFloat
    var state: PetState
    var mode: PetMode
    var modeUntil = 0.0
    var frameI = 0
    var shownSet = -1, shownFrame = -1    // 0 走 / 1 跑 / 2 笑
    var distAcc: CGFloat = 0
    var turnIn = rnd(0.8, 2.2)
    var alertAt: Double?
    var caughtAt = 0.0
    var laughEnd: Double?
    var enterTarget: CGFloat = 0
    var voice: Int?
    var facingRight = true
    var dead = false
    var counts = true                     // 被点中才算「已抓」；瞬爆的不算

    init(x: CGFloat, y: CGFloat, vx: CGFloat, speed: CGFloat, size: CGSize) {
        id = Pet.nextID; Pet.nextID += 1
        self.x = x; self.y = y; self.vx = vx; self.vy = 0
        self.speed = speed
        state = .enter
        mode = .run
        facingRight = vx >= 0
        node.size = size
    }
}

// MARK: - 场景：所有奶蛙都画在这一个全屏透明层上

final class PetScene: SKScene {
    var pets: [Pet] = []
    var spriteH: CGFloat = 115
    var charH: CGFloat { spriteH * 0.8 }
    var walkSpeed: CGFloat { WALK_K * charH }
    var walkFast: CGFloat { WALK_MAX_K * charH }
    var runMax: CGFloat { RUN_MAX_K * charH }
    var enterSpeed: CGFloat { ENTER_K * charH }
    var runStart: CGFloat { RUN_START_K * charH }
    var alertR: CGFloat { ALERT_K * charH }
    var panicR: CGFloat { PANIC_K * charH }
    var calmR: CGFloat { CALM_K * charH }
    var spriteSize: CGSize { CGSize(width: CGFloat(A.fw) * spriteH / CGFloat(A.fh), height: spriteH) }

    var sound: Sound!
    weak var overlay: NSWindow?
    var onStats: (() -> Void)?

    var lastT = 0.0
    var now = 0.0
    var cursor = CGPoint(x: -9999, y: -9999)
    var lastCursor: CGPoint?
    var cursorSpeed: CGFloat = 0
    var hovering = false

    var summonPending = 0
    var songQueue: [Pet] = [], songRate = 0.0, songAcc = 0.0
    var boomQueue: [Pet] = [], boomRate = 0.0, boomAcc = 0.0
    var liveBursts = 0

    var interval = 15.0
    var nextSpawnAt = 0.8
    var caughtTotal = 0
    var statsAt = 0.0

    var nextSpawnIn: Int { interval > 0 ? max(0, Int(ceil(nextSpawnAt - now))) : -1 }

    override func update(_ t: TimeInterval) {
        let dt = lastT == 0 ? 1.0 / 60 : min(0.05, max(0, t - lastT))
        lastT = t
        now += dt
        readCursor(dt)
        pumpQueues(dt)
        let W = size.width, H = size.height
        var anyDead = false
        for p in pets where !p.dead {
            step(p, dt: dt, W: W, H: H)
            if p.dead { anyDead = true }
        }
        if anyDead { pets.removeAll { $0.dead } }
        if interval > 0, now >= nextSpawnAt {
            if pets.count < MAX_PETS { spawn(bulk: false) }
            nextSpawnAt = now + interval
        }
        updateHover()
        // 没有奶蛙、没有烟花时降到低帧率，省电
        let busy = !pets.isEmpty || liveBursts > 0 || summonPending > 0
        view?.preferredFramesPerSecond = busy ? 60 : 4
        if now - statsAt >= 0.25 { statsAt = now; onStats?() }
    }

    func readCursor(_ dt: Double) {
        guard let win = view?.window else { return }
        let m = NSEvent.mouseLocation
        let p = CGPoint(x: m.x - win.frame.minX, y: m.y - win.frame.minY)
        if let lc = lastCursor, dt > 0 {
            let inst = hypot(p.x - lc.x, p.y - lc.y) / CGFloat(dt)
            cursorSpeed = cursorSpeed * 0.6 + inst * 0.4
        }
        lastCursor = p
        cursor = p
    }

    // MARK: 出生

    /// bulk = 批量召唤：随机高度、跑到屏幕里随机位置再开始闲逛；
    /// 单只（定时出现）和原版一样从边缘跑进来，刚露全身就停下闲逛。
    func spawn(bulk: Bool) {
        let s = spriteSize, W = size.width, H = size.height
        let fromLeft = Bool.random()
        let y: CGFloat
        if bulk {
            y = CGFloat.random(in: s.height / 2 ... max(s.height / 2 + 1, H - s.height / 2))
        } else {
            let my = max(150, H * 0.14)
            y = CGFloat.random(in: (my + s.height / 2) ... max(my + s.height / 2 + 1, H - my - s.height / 2))
        }
        let x = fromLeft ? -s.width / 2 - 8 : W + s.width / 2 + 8
        let p = Pet(x: x, y: y, vx: fromLeft ? 1 : -1, speed: enterSpeed, size: s)
        if bulk {
            p.enterTarget = CGFloat.random(in: s.width / 2 ... max(s.width / 2 + 1, W - s.width / 2))
        } else {
            p.enterTarget = fromLeft ? s.width / 2 : W - s.width / 2
        }
        p.node.texture = A.run.first
        addChild(p.node)
        pets.append(p)
        draw(p)
    }

    func summon(_ n: Int) {
        if n == 1 { if pets.count < MAX_PETS { spawn(bulk: false) }; return }
        let room = MAX_PETS - pets.count - summonPending
        summonPending += max(0, min(n, room))
    }

    // MARK: 每帧

    func speedFor(_ d: CGFloat) -> CGFloat {
        if d >= D_FAR { return walkSpeed }
        if d >= D_RUN {
            let t = (D_FAR - d) / (D_FAR - D_RUN)
            return walkSpeed + (walkFast - walkSpeed) * t
        }
        let t = max(0, min(1, (D_RUN - d) / (D_RUN - D_NEAR)))
        return walkFast + (runMax - walkFast) * pow(t, 1.35)
    }

    /// 按鼠标距离选走 / 跑，带迟滞和最短保持时间（原版的做法）；逃跑中速度够了就一直用跑的动作。
    func pickMode(_ p: Pet, _ dist: CGFloat) -> PetMode {
        if now < p.modeUntil { return p.mode }
        if p.state == .flee && p.speed >= runStart { return .run }
        if dist <= D_RUN_ON && p.speed >= runStart { return .run }
        if dist >= D_RUN_OFF { return .walk }
        return p.mode
    }

    func setMode(_ p: Pet, _ m: PetMode) {
        guard m != p.mode else { return }
        p.mode = m
        p.modeUntil = now + MODE_HOLD
        p.distAcc = 0
    }

    /// 按走过的距离翻帧，脚步和位移对得上。
    func advance(_ p: Pet, _ dt: CGFloat) {
        if p.speed < 1 { return }
        let stride = (p.mode == .walk ? WALK_STRIDE_K : RUN_STRIDE_K) * charH / CGFloat(N_FRAMES)
        p.distAcc += p.speed * dt
        var steps = 0
        while p.distAcc >= stride && steps < 2 {
            p.distAcc -= stride
            p.frameI = (p.frameI + 1) % N_FRAMES
            steps += 1
        }
        if steps >= 2 { p.distAcc = 0 }
    }

    func step(_ p: Pet, dt: Double, W: CGFloat, H: CGFloat) {
        let w = p.node.size.width, h = p.node.size.height
        let fdt = CGFloat(dt)
        switch p.state {
        case .caught:
            updateCaught(p)
            return
        case .enter:
            p.x += p.vx * p.speed * fdt
            advance(p, fdt)
            if (p.vx > 0 && p.x >= p.enterTarget) || (p.vx < 0 && p.x <= p.enterTarget) {
                p.state = .idle
                p.turnIn = rnd(0.6, 1.4)
            }
            draw(p)
            return
        default:
            break
        }

        let dist = hypot(cursor.x - p.x, cursor.y - p.y)
        var target = speedFor(dist)
        if p.state == .flee { target = max(target, runMax) }
        p.speed += (target - p.speed) * min(1, fdt * 8)
        setMode(p, pickMode(p, dist))

        if p.state == .idle {
            let noticed = dist < panicR || (dist < alertR && cursorSpeed > CURSOR_SPEED_LIMIT)
            if noticed {
                if let a = p.alertAt {
                    if now - a >= REACT_DELAY { p.state = .flee; p.alertAt = nil }
                } else {
                    p.alertAt = now
                }
            } else {
                p.alertAt = nil
            }
        }

        if p.state == .idle {
            p.turnIn -= dt
            if p.turnIn <= 0 {
                p.turnIn = rnd(0.8, 2.4)
                let ang = CGFloat.random(in: 0 ..< 2 * .pi)
                var vx = cos(ang), vy = sin(ang) * 0.55
                let n = max(hypot(vx, vy), 1e-6)
                vx /= n; vy /= n
                p.vx = vx; p.vy = vy
            }
        } else if p.state == .flee {
            let ang = atan2(p.y - cursor.y, p.x - cursor.x)
            p.vx = cos(ang); p.vy = sin(ang)
            if dist > calmR && p.x - w / 2 >= 0 && p.x + w / 2 <= W {
                p.state = .idle
                p.turnIn = rnd(0.6, 1.6)
            }
        }

        p.facingRight = p.vx >= 0
        advance(p, fdt)
        p.x += p.vx * p.speed * fdt
        p.y += p.vy * p.speed * fdt
        // 整只跑出左右边缘 = 逃走
        if p.x <= -w / 2 || p.x >= W + w / 2 { kill(p); return }
        if p.y - h / 2 < 0 { p.y = h / 2; p.vy = abs(p.vy) }
        else if p.y + h / 2 > H { p.y = H - h / 2; p.vy = -abs(p.vy) }
        draw(p)
    }

    func draw(_ p: Pet) {
        let set = p.state == .caught ? 2 : (p.mode == .walk ? 0 : 1)
        if set != p.shownSet || p.frameI != p.shownFrame {
            let tex = set == 0 ? A.walk : (set == 1 ? A.run : A.laugh)
            if p.frameI < tex.count { p.node.texture = tex[p.frameI] }
            p.shownSet = set
            p.shownFrame = p.frameI
        }
        p.node.xScale = p.facingRight ? 1 : -1
        p.node.position = CGPoint(x: p.x, y: p.y)
        // 越靠下的越靠前；正在笑的盖在最上面
        let H = max(size.height, 1)
        p.node.zPosition = (p.state == .caught ? 200 : 0) + (H - p.y) / H * 100
    }

    func kill(_ p: Pet) {
        p.dead = true
        p.node.removeFromParent()
        if let v = p.voice { sound.stopLaugh(v, owner: p.id); p.voice = nil }
    }

    // MARK: 抓到

    func catchPet(_ p: Pet) {
        guard !p.dead, p.state != .caught else { return }
        p.state = .caught
        p.caughtAt = now
        p.laughEnd = nil
        p.frameI = 0
        p.voice = sound.laugh(owner: p.id)
        draw(p)
    }

    func updateCaught(_ p: Pet) {
        let n = A.laugh.count
        let idx = Int((now - p.caughtAt) * LAUGH_FPS)
        if idx >= LAUGH_LIE_FRAME, let v = p.voice { sound.stopLaugh(v, owner: p.id); p.voice = nil }
        if idx < n {
            if idx != p.frameI { p.frameI = idx; draw(p) }
            return
        }
        if p.frameI != n - 1 { p.frameI = n - 1; draw(p) }
        guard let end = p.laughEnd else { p.laughEnd = now; return }
        if now - end >= BURST_HOLD {
            burst(at: p.node.position)
            sound.boom(now: now, minGap: 0.08)
            if p.counts { caughtTotal += 1; UserDefaults.standard.set(caughtTotal, forKey: "caught") }
            kill(p)
        }
    }

    // MARK: 烟花

    func burst(at pt: CGPoint) {
        let s = spriteH / 115
        guard liveBursts < BOOM_MAX_LIVE else { poof(at: pt, scale: s); return }
        liveBursts += 1
        let c1 = PALETTE.randomElement()!, c2 = PALETTE.randomElement()!
        let e = SKEmitterNode()
        e.particleTexture = A.spark
        e.numParticlesToEmit = 90
        e.particleBirthRate = 9000
        e.particleLifetime = 1.1
        e.particleLifetimeRange = 0.6
        e.emissionAngleRange = .pi * 2
        e.particleSpeed = 250 * s
        e.particleSpeedRange = 220 * s
        e.yAcceleration = -230 * s
        e.particleAlphaSpeed = -0.8
        e.particleScale = 0.5 * s
        e.particleScaleRange = 0.3 * s
        e.particleScaleSpeed = -0.3 * s
        e.particleColorBlendFactor = 1
        e.particleColorSequence = SKKeyframeSequence(keyframeValues: [NSColor.white, c1, c2], times: [0, 0.15, 1])
        e.position = pt
        e.zPosition = 500
        addChild(e)
        e.run(.sequence([.wait(forDuration: 2.3), .run { [weak self] in self?.liveBursts -= 1 }, .removeFromParent()]))
        poof(at: pt, scale: s * 1.6)
    }

    func poof(at pt: CGPoint, scale s: CGFloat) {
        let f = SKSpriteNode(texture: A.spark)
        f.size = CGSize(width: 40 * s, height: 40 * s)
        f.position = pt
        f.zPosition = 501
        addChild(f)
        f.run(.sequence([.group([.scale(to: 3, duration: 0.25), .fadeOut(withDuration: 0.25)]), .removeFromParent()]))
    }

    // MARK: 控制条按钮

    /// 仙乐：全场奶蛙一只接一只开始笑，之后各自走 笑→躺平→烟花→消失。
    func serenade() {
        songQueue = pets.filter { !$0.dead && $0.state != .caught }.shuffled()
        let dur = min(3.0, max(0.5, Double(songQueue.count) * 0.12))
        songRate = Double(songQueue.count) / dur
        songAcc = 0
    }

    /// 瞬爆：一只接一只炸，最多 2.6 秒全部点着。
    func boomAll() {
        boomQueue = pets.filter { !$0.dead && $0.state != .caught }.shuffled()
        let dur = min(2.6, max(0.3, Double(boomQueue.count) * 0.08))
        boomRate = Double(boomQueue.count) / dur
        boomAcc = 0
    }

    func clearAll() {
        summonPending = 0
        songQueue.removeAll()
        boomQueue.removeAll()
        for p in pets { p.dead = true; p.node.removeFromParent() }
        pets.removeAll()
        sound.stopAll()
    }

    func pumpQueues(_ dt: Double) {
        if summonPending > 0 {
            let k = min(summonPending, 40)   // 错峰出生，点下去不卡
            for _ in 0..<k { spawn(bulk: true) }
            summonPending -= k
        }
        if !songQueue.isEmpty {
            songAcc += songRate * dt
            var k = Int(songAcc); songAcc -= Double(k)
            while k > 0, let p = songQueue.popLast() { catchPet(p); k -= 1 }
        }
        if !boomQueue.isEmpty {
            boomAcc += boomRate * dt
            var k = Int(boomAcc); boomAcc -= Double(k)
            while k > 0, let p = boomQueue.popLast() {
                if !p.dead && p.state != .caught {
                    burst(at: p.node.position)
                    sound.boom(now: now, minGap: 0.12)
                    kill(p)
                }
                k -= 1
            }
        }
    }

    func setSpriteH(_ h: CGFloat) {
        spriteH = h
        let s = spriteSize
        for p in pets { p.node.size = s }
    }

    // MARK: 鼠标

    func hitPet(at pt: CGPoint) -> Pet? {
        var best: Pet?
        for p in pets where !p.dead {
            let s = p.node.size
            let lx0 = (pt.x - p.x) / s.width + 0.5
            let ly = (pt.y - p.y) / s.height + 0.5
            guard lx0 >= 0, lx0 < 1, ly >= 0, ly < 1, p.shownFrame >= 0 else { continue }
            let lx = p.facingRight ? lx0 : 1 - lx0
            let masks = p.shownSet == 2 ? A.laughMask : (p.shownSet == 1 ? A.runMask : A.walkMask)
            guard p.shownFrame < masks.count else { continue }
            let px = min(A.fw - 1, Int(lx * CGFloat(A.fw)))
            let py = min(A.fh - 1, Int((1 - ly) * CGFloat(A.fh)))
            if masks[p.shownFrame][py * A.fw + px] >= HIT_ALPHA {
                if best == nil || p.node.zPosition > best!.node.zPosition { best = p }
            }
        }
        return best
    }

    /// 只有鼠标压在奶蛙身上时才接点击，其余时候整层鼠标穿透。
    func updateHover() {
        let want = !pets.isEmpty && hitPet(at: cursor) != nil
        if want != hovering {
            hovering = want
            overlay?.ignoresMouseEvents = !want
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let p = hitPet(at: event.location(in: self)), p.state != .caught {
            naiwaLog("点中一只（屏幕内 \(pets.count) 只）")
            catchPet(p)
        }
    }
}

final class PetView: SKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - 程序

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSTextFieldDelegate {
    var overlay: NSPanel!
    var skView: PetView!
    var scene: PetScene!
    var panel: KeyPanel!
    var statusItem: NSStatusItem!
    var hotKeyRefs: [EventHotKeyRef?] = []

    let statusLabel = NSTextField(labelWithString: "")
    let countSeg = NSSegmentedControl(labels: COUNTS.map { "\($0)" }, trackingMode: .selectOne, target: nil, action: nil)
    let customField = NSTextField()
    let intervalPop = NSPopUpButton()
    let sizePop = NSPopUpButton()
    let soundBtn = NSButton(title: "音效 开", target: nil, action: nil)
    let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ note: Notification) {
        A.load()
        guard !A.walk.isEmpty, !A.laugh.isEmpty else {
            let a = NSAlert()
            a.messageText = "奶蛙素材没找到"
            a.informativeText = "App 包里的 Resources/frames 缺失，请重新安装。"
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        defaults.register(defaults: ["interval": 15.0, "sizeIndex": 1, "sound": true, "countIndex": 1, "caught": 0])
        naiwaLog("启动")
        setupOverlay()
        setupPanel()
        setupStatusItem()
        registerHotKeys()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        refreshStats()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    func applicationWillTerminate(_ note: Notification) {
        defaults.set(scene?.caughtTotal ?? 0, forKey: "caught")
    }

    // MARK: 覆盖层

    func mainScreenFrame() -> NSRect { (NSScreen.screens.first ?? NSScreen.main)?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }

    func setupOverlay() {
        let f = mainScreenFrame()
        overlay = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        overlay.ignoresMouseEvents = true
        overlay.hidesOnDeactivate = false
        overlay.isReleasedWhenClosed = false

        skView = PetView(frame: NSRect(origin: .zero, size: f.size))
        skView.allowsTransparency = true
        skView.ignoresSiblingOrder = true
        skView.preferredFramesPerSecond = 60
        overlay.contentView = skView

        scene = PetScene(size: f.size)
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear
        scene.overlay = overlay
        scene.sound = Sound(laugh: A.laughWav, boom: A.boomWav)
        scene.sound.enabled = defaults.bool(forKey: "sound")
        scene.interval = defaults.double(forKey: "interval")
        scene.nextSpawnAt = 0.8
        scene.caughtTotal = defaults.integer(forKey: "caught")
        let si = max(0, min(SIZES.count - 1, defaults.integer(forKey: "sizeIndex")))
        scene.spriteH = SIZES[si].0
        scene.onStats = { [weak self] in self?.refreshStats() }
        skView.presentScene(scene)

        overlay.setFrame(f, display: true)
        overlay.orderFrontRegardless()
    }

    @objc func screensChanged() {
        let f = mainScreenFrame()
        overlay.setFrame(f, display: true)
        skView.frame = NSRect(origin: .zero, size: f.size)
        placePanel()
    }

    // MARK: 控制条

    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        v.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return v
    }

    func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 6
        r.distribution = .fill
        return r
    }

    func setupPanel() {
        let W: CGFloat = 520
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: 130),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .vibrantDark)

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        panel.contentView = fx

        // 第一行：标题 / 统计 / 清零 / 收起
        let icon = NSImageView(image: A.menuIcon ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let title = NSTextField(labelWithString: "奶蛙")
        title.font = .boldSystemFont(ofSize: 15)
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let reset = button("清零", #selector(resetCaught))
        reset.controlSize = .small
        reset.toolTip = "把累计「已抓」清零"
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "收起") ?? NSImage(),
                             target: self, action: #selector(hidePanel))
        close.isBordered = false
        close.toolTip = "收起控制条（菜单栏的奶蛙图标或 ⌃⌥P 可以叫回来）"
        let r1 = row([icon, title, statusLabel, spacer(), reset, close])

        // 第二行：自动出现间隔 / 大小 / 音效 / 清屏 / 退出
        let l1 = NSTextField(labelWithString: "自动出现")
        intervalPop.addItems(withTitles: INTERVALS.map { $0.1 })
        let cur = defaults.double(forKey: "interval")
        intervalPop.selectItem(at: INTERVALS.firstIndex { $0.0 == cur } ?? 2)
        intervalPop.target = self
        intervalPop.action = #selector(intervalChanged)
        let l2 = NSTextField(labelWithString: "大小")
        sizePop.addItems(withTitles: SIZES.map { $0.1 })
        sizePop.selectItem(at: max(0, min(SIZES.count - 1, defaults.integer(forKey: "sizeIndex"))))
        sizePop.target = self
        sizePop.action = #selector(sizeChanged)
        soundBtn.target = self
        soundBtn.action = #selector(toggleSound)
        soundBtn.bezelStyle = .rounded
        soundBtn.title = scene.sound.enabled ? "音效 开" : "音效 关"
        let clear = button("清屏", #selector(clearAll))
        let quit = button("退出", #selector(quitFromButton))
        quit.toolTip = "关掉奶蛙程序（⌃⌥Q）。只想藏起控制条点右上角 ×"
        let r2 = row([l1, intervalPop, l2, sizePop, soundBtn, spacer(), clear, quit])

        // 第三行：数量 / 自定义 / 召唤 / 仙乐 / 瞬爆
        countSeg.selectedSegment = max(0, min(COUNTS.count - 1, defaults.integer(forKey: "countIndex")))
        countSeg.target = self
        countSeg.action = #selector(countChanged)
        customField.placeholderString = "自定义"
        customField.alignment = .center
        customField.delegate = self
        customField.target = self
        customField.action = #selector(summonClicked)
        customField.translatesAutoresizingMaskIntoConstraints = false
        customField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let summonBtn = button("召唤", #selector(summonClicked))
        summonBtn.keyEquivalent = "\r"
        let song = button("仙乐", #selector(serenade))
        song.toolTip = "全场奶蛙一起笑，笑完各自放烟花"
        let boom = button("瞬爆", #selector(boomAll))
        boom.toolTip = "全场奶蛙一只接一只放烟花"
        let r3 = row([countSeg, customField, spacer(), summonBtn, song, boom])

        let v = NSStackView(views: [r1, r2, r3])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 10
        v.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 12)
        v.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            v.topAnchor.constraint(equalTo: fx.topAnchor),
            v.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            v.widthAnchor.constraint(equalToConstant: W),
        ])
        for r in [r1, r2, r3] { r.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -26).isActive = true }
        fx.layoutSubtreeIfNeeded()
        panel.setContentSize(v.fittingSize)
        placePanel()
        panel.orderFrontRegardless()
    }

    func placePanel() {
        guard let panel = panel, let s = NSScreen.screens.first else { return }
        let vf = s.visibleFrame, sz = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - sz.width - 16, y: vf.minY + 16))
    }

    func refreshStats() {
        guard let scene = scene else { return }
        var s = "· 屏幕内 \(scene.pets.count) 只 · 已抓 \(scene.caughtTotal)"
        if scene.pets.count >= MAX_PETS { s += " · 已满 \(MAX_PETS) 只" }
        else if scene.nextSpawnIn >= 0 { s += " · 下一只 \(scene.nextSpawnIn)s" }
        statusLabel.stringValue = s
    }

    @objc func showPanel() { panel.orderFrontRegardless() }
    @objc func hidePanel() { panel.orderOut(nil) }
    @objc func togglePanel() { panel.isVisible ? hidePanel() : showPanel() }

    @objc func intervalChanged() {
        let v = INTERVALS[max(0, intervalPop.indexOfSelectedItem)].0
        scene.interval = v
        scene.nextSpawnAt = scene.now + v
        defaults.set(v, forKey: "interval")
        refreshStats()
    }

    @objc func sizeChanged() {
        let i = max(0, sizePop.indexOfSelectedItem)
        scene.setSpriteH(SIZES[i].0)
        defaults.set(i, forKey: "sizeIndex")
    }

    @objc func countChanged() {
        customField.stringValue = ""
        defaults.set(countSeg.selectedSegment, forKey: "countIndex")
    }

    func controlTextDidChange(_ obj: Notification) {
        let digits = customField.stringValue.filter { $0.isNumber }
        if digits != customField.stringValue { customField.stringValue = digits }
    }

    @objc func summonClicked() {
        var n = COUNTS[max(0, countSeg.selectedSegment)]
        if let c = Int(customField.stringValue), c > 0 { n = min(c, MAX_PETS) }
        scene.summon(n)
    }

    @objc func summonOne() { scene.summon(1) }
    @objc func summon10() { scene.summon(10) }
    @objc func summon100() { scene.summon(100) }
    @objc func summon999() { scene.summon(999) }
    @objc func serenade() { scene.serenade() }
    @objc func boomAll() { scene.boomAll() }
    @objc func clearAll() { scene.clearAll(); refreshStats() }

    @objc func toggleSound() {
        scene.sound.enabled.toggle()
        if !scene.sound.enabled { scene.sound.stopAll() }
        soundBtn.title = scene.sound.enabled ? "音效 开" : "音效 关"
        defaults.set(scene.sound.enabled, forKey: "sound")
    }

    @objc func resetCaught() {
        scene.caughtTotal = 0
        defaults.set(0, forKey: "caught")
        refreshStats()
    }

    func quit(_ from: String) {
        naiwaLog("退出：\(from)")
        NSApp.terminate(nil)
    }
    @objc func quitFromButton() { quit("控制条按钮") }
    @objc func quitFromMenu() { quit("菜单栏") }

    // MARK: 菜单栏

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            if let img = A.menuIcon { b.image = img } else { b.title = "🐸" }
            b.toolTip = "奶蛙"
        }
        let m = NSMenu()
        m.delegate = self
        statusItem.menu = m
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        func item(_ t: String, _ a: Selector?, _ key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: key)
            i.target = self
            if !key.isEmpty { i.keyEquivalentModifierMask = [.control, .option] }
            return i
        }
        let head = NSMenuItem(title: "屏幕内 \(scene.pets.count) 只 · 已抓 \(scene.caughtTotal)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        m.addItem(.separator())
        m.addItem(item(panel.isVisible ? "收起控制条" : "显示控制条", #selector(togglePanel), "p"))
        m.addItem(.separator())
        m.addItem(item("召唤 1 只", #selector(summonOne), "n"))
        m.addItem(item("召唤 10 只", #selector(summon10)))
        m.addItem(item("召唤 100 只", #selector(summon100)))
        m.addItem(item("召唤 999 只", #selector(summon999)))
        m.addItem(item("仙乐（全场一起笑）", #selector(serenade)))
        m.addItem(item("瞬爆（全场放烟花）", #selector(boomAll)))
        m.addItem(item("清屏", #selector(clearAll)))
        m.addItem(.separator())
        let snd = item("音效", #selector(toggleSound))
        snd.state = scene.sound.enabled ? .on : .off
        m.addItem(snd)
        m.addItem(.separator())
        m.addItem(item("退出奶蛙", #selector(quitFromMenu), "q"))
    }

    // MARK: 全局热键 ⌃⌥Q / ⌃⌥N / ⌃⌥P

    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = Int(hk.id)
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.hotKey(id) }
            return noErr
        }, 1, &spec, nil, nil)
        let mods = UInt32(controlKey | optionKey)
        for (id, key) in [(1, kVK_ANSI_Q), (2, kVK_ANSI_N), (3, kVK_ANSI_P)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x4E41_5741), id: UInt32(id)),
                                GetApplicationEventTarget(), 0, &ref)
            hotKeyRefs.append(ref)
        }
    }

    func hotKey(_ id: Int) {
        switch id {
        case 1: quit("热键 ⌃⌥Q")
        case 2: summonOne()
        case 3: togglePanel()
        default: break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
