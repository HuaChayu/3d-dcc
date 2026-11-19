import Foundation
import AppKit

/// .blend 导入的「Base Color 开口烘焙」。
///
/// 为什么必须烘：Blender 材质的 Base Color 口后面常挂着一整条节点链
/// （正片叠底 → 混合 → 色带 → 节点组 → 程序化噪声…），口上那个默认值只是链末端的乘色，
/// 而链上任何一张图都**不是**表面最终看到的颜色。想「和 Blender 里一模一样」，
/// 只有让 Blender 自己求值一次：把 Base Color 口接成自发光烘成一张 PNG。
///
/// 为了不引入运行期依赖，只在导入 .blend 时**顺带**跑一次本机 Blender 后台模式，
/// 结果按材质缓存到 .blend 同目录的 `.marvis_bake/<blend名>/<材质名>.png`，
/// 之后解析器直接读缓存图，不再重复烘。
enum Blender烘焙 {
    /// 关掉就完全退回「顺着链路猜一张图」的旧行为
    static var 启用: Bool {
        get {
            if UserDefaults.standard.object(forKey: 开关键) == nil { return true }
            return UserDefaults.standard.bool(forKey: 开关键)
        }
        set { UserDefaults.standard.set(newValue, forKey: 开关键) }
    }
    private static let 开关键 = "导入.blend烘焙基础色"
    static let 烘焙尺寸 = 2048
    /// 单次烘焙的超时秒数：模型大、材质多时会久一点，超时就当没成功，退回旧逻辑
    static let 超时秒: Double = 600

    // MARK: - 缓存位置

    static func 缓存目录(blend: URL) -> URL {
        blend.deletingLastPathComponent()
            .appendingPathComponent(".marvis_bake", isDirectory: true)
            .appendingPathComponent(blend.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    /// 材质名 → 文件名。解析器读出来的名字已经去掉 "MA." 前缀，这里再兜一次，保证两边一致。
    static func 规范名(_ 名: String) -> String {
        var s = 名
        if s.hasPrefix("MA.") { s.removeFirst(3) }
        else if s.hasPrefix("MA") { s.removeFirst(2) }
        while s.hasPrefix(".") { s.removeFirst() }
        s = 文件名清理.替换非法字符(s, 禁: CharacterSet(charactersIn: "/\\:*?\"<>|"), 去空段: false, 兜底: "")
        return s.isEmpty ? "材质" : s
    }

    static func 图路径(blend: URL, 材质名: String) -> URL {
        缓存目录(blend: blend).appendingPathComponent(规范名(材质名) + ".png")
    }

    /// 命中缓存就返回图片字节；没烘过返回 nil（调用方退回原链路）
    static func 读图(blend: URL?, 材质名: String) -> Data? {
        guard let blend else { return nil }
        let 目录 = 缓存目录(blend: blend)
        let 名 = 规范名(材质名)
        let 精确 = 目录.appendingPathComponent(名 + ".png")
        if let 值 = try? 精确.resourceValues(forKeys: [.fileSizeKey]), (值.fileSize ?? 0) > 0 {
            return try? Data(contentsOf: 精确)
        }
        // 材质重名会被加后缀（Human 2 / Human.001），按前缀兜一次
        let 名单 = 目录名单.读(目录)
        if let 命中 = 名单.filter({ $0.hasSuffix(".png") }).first(where: {
            let 茎 = String($0.dropLast(4))
            return 茎 == 名 || 茎.hasPrefix(名 + " ") || 茎.hasPrefix(名 + ".")
        }) {
            return try? Data(contentsOf: 目录.appendingPathComponent(命中))
        }
        return nil
    }

    // MARK: - 执行

    private static let 锁 = NSLock()

    /// 缓存是否还能用：完成标记比 .blend 新，且目录里确实有图
    static func 缓存有效(blend: URL) -> Bool {
        let 目录 = 缓存目录(blend: blend)
        let 标记 = 目录.appendingPathComponent(".done")
        guard let 标时 = try? 标记.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              let 源时 = try? blend.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              标时 >= 源时 else { return false }
        let 图们 = 目录名单.读(目录).filter { $0.hasSuffix(".png") }
        return !图们.isEmpty
    }

    /// 导入 .blend 前调一次：需要且能烘就烘完再返回。
    /// 返回一句写进导入报告的话（失败也给原因，别静默）。
    @discardableResult
    static func 确保烘焙(blend: URL) -> String? {
        guard 启用 else { return nil }
        guard 缓存有效(blend: blend) else { return 执行烘焙(blend: blend) }
        return nil
    }

    private static func 执行烘焙(blend: URL) -> String? {
        guard let blender = 找Blender() else {
            return "未找到本机 Blender，基础色退回「按链路猜图」（表面颜色可能和 Blender 不一致）"
        }
        锁.lock()
        defer { 锁.unlock() }
        // 等锁期间别的线程可能已经烘完
        if 缓存有效(blend: blend) { return nil }

        let 目录 = 缓存目录(blend: blend)
        do {
            try FileManager.default.createDirectory(at: 目录, withIntermediateDirectories: true)
        } catch {
            return "烘焙目录创建失败：\(error.localizedDescription)"
        }

        let 脚本 = 目录.appendingPathComponent("bake_basecolor.py")
        do {
            try 烘焙脚本.write(to: 脚本, atomically: true, encoding: .utf8)
        } catch {
            return "烘焙脚本写入失败：\(error.localizedDescription)"
        }

        let 进程 = Process()
        进程.executableURL = blender
        进程.arguments = ["-b", blend.path, "--python", 脚本.path, "--",
                       目录.path, "\(烘焙尺寸)"]
        进程.currentDirectoryURL = blend.deletingLastPathComponent()
        let 日志 = 目录.appendingPathComponent("bake.log")
        FileManager.default.createFile(atPath: 日志.path, contents: nil)
        let 柄 = try? FileHandle(forWritingTo: 日志)
        进程.standardOutput = 柄 ?? FileHandle.nullDevice
        进程.standardError = 柄 ?? FileHandle.nullDevice

        print("[blend烘焙] 开始烘焙 Base Color：\(blend.lastPathComponent) → \(目录.path)")
        let 起 = Date()
        do {
            try 进程.run()
        } catch {
            try? 柄?.close()
            return "调用 Blender 失败：\(error.localizedDescription)"
        }

        // 超时兜底：等太久就杀掉，别把导入卡死
        let 截止 = Date().addingTimeInterval(超时秒)
        while 进程.isRunning, Date() < 截止 {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if 进程.isRunning {
            进程.terminate()
            try? 柄?.close()
            return "Blender 烘焙超时（>\(Int(超时秒))s），已终止，基础色退回按链路猜图"
        }
        try? 柄?.close()
        let 耗时 = String(format: "%.1f", Date().timeIntervalSince(起))

        let 图们 = 目录名单.读(目录).filter { $0.hasSuffix(".png") }
        guard !图们.isEmpty else {
            return "Blender 烘焙没有产出贴图（退出码 \(进程.terminationStatus)），详情见 \(日志.path)"
        }
        try? Data().write(to: 目录.appendingPathComponent(".done"))
        print("[blend烘焙] 完成 \(图们.count) 张，耗时 \(耗时)s")
        return "已用 Blender 烘焙 \(图们.count) 个材质的 Base Color（\(耗时)s），导入表面颜色与 Blender 一致"
    }

    private static func 找Blender() -> URL? {
        var 候选: [String] = []
        if let 环境 = ProcessInfo.processInfo.environment["BLENDER_BIN"], !环境.isEmpty {
            候选.append(环境)
        }
        候选 += [
            "/Applications/Blender.app/Contents/MacOS/Blender",
            "/Applications/Blender.app/Contents/MacOS/blender",
            NSHomeDirectory() + "/Applications/Blender.app/Contents/MacOS/Blender",
            "/Applications/Blender 5.4.app/Contents/MacOS/Blender",
        ]
        for 路 in 候选 where FileManager.default.isExecutableFile(atPath: 路) {
            return URL(fileURLWithPath: 路)
        }
        // 兜底：扫一遍常见应用目录里名字带 Blender 的 .app（用户可能装在别的版本目录）
        for 根 in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let 名单 = 目录名单.读(URL(fileURLWithPath: 根))
            for 名 in 名单 where 名.lowercased().hasSuffix(".app") && 名.lowercased().contains("blender") {
                for 内 in ["Contents/MacOS/Blender", "Contents/MacOS/blender"] {
                    let 路 = 根 + "/" + 名 + "/" + 内
                    if FileManager.default.isExecutableFile(atPath: 路) {
                        return URL(fileURLWithPath: 路)
                    }
                }
            }
        }
        return nil
    }

    // MARK: - 烘焙脚本

    /// 思路：给每个材质做一份副本，把 Principled 的 Base Color 口
    /// （连着的就直接接源 socket，没连就接常量）喂给自发光，再用 EMIT 烘。
    /// EMIT 烘出来的就是「Base Color 口的最终结果」，不掺灯光、不掺着色。
    private static let 烘焙脚本 = #"""
import bpy, os, sys

argv = sys.argv
args = argv[argv.index("--") + 1:] if "--" in argv else []
OUT = args[0] if args else "/tmp/marvis_bake"
SIZE = int(args[1]) if len(args) > 1 else 2048
os.makedirs(OUT, exist_ok=True)

def clean(name):
    s = name
    if s.startswith("MA."):
        s = s[3:]
    elif s.startswith("MA"):
        s = s[2:]
    while s.startswith("."):
        s = s[1:]
    for ch in '/\\:*?"<>|':
        s = s.replace(ch, "_")
    return s or "材质"

objs = [o for o in bpy.data.objects if o.type == 'MESH']
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 4
scene.cycles.use_denoising = False
scene.render.bake.use_selected_to_active = False
scene.render.bake.margin = 8
scene.render.bake.use_clear = True

def emissive_copy(mat):
    if not mat.use_nodes or not mat.node_tree:
        return None
    nt = mat.node_tree
    principled = next((n for n in nt.nodes if n.bl_idname == 'ShaderNodeBsdfPrincipled'), None)
    out = next((n for n in nt.nodes if n.bl_idname == 'ShaderNodeOutputMaterial'), None)
    if principled is None or out is None:
        return None
    bc = principled.inputs.get('Base Color')
    if bc is None:
        return None
    cp = mat.copy()
    cp.name = mat.name + "_BAKE"
    nt2 = cp.node_tree
    p2 = next(n for n in nt2.nodes if n.bl_idname == 'ShaderNodeBsdfPrincipled')
    o2 = next(n for n in nt2.nodes if n.bl_idname == 'ShaderNodeOutputMaterial')
    bc2 = p2.inputs.get('Base Color')
    em = nt2.nodes.new('ShaderNodeEmission')
    em.inputs['Strength'].default_value = 1.0
    if bc2.is_linked:
        nt2.links.new(bc2.links[0].from_socket, em.inputs['Color'])
    else:
        em.inputs['Color'].default_value = bc2.default_value
    for l in list(o2.inputs['Surface'].links):
        nt2.links.remove(l)
    nt2.links.new(em.outputs['Emission'], o2.inputs['Surface'])
    tex = nt2.nodes.new('ShaderNodeTexImage')
    img = bpy.data.images.new(clean(mat.name) + "_BASE", SIZE, SIZE, alpha=False)
    tex.image = img
    for n in nt2.nodes:
        n.select = False
    tex.select = True
    nt2.nodes.active = tex
    return cp, img

done = 0
for mat in list(bpy.data.materials):
    got = emissive_copy(mat)
    if not got:
        print("SKIP(no principled):", mat.name)
        continue
    cp, img = got
    ok = False
    for o in objs:
        if o.hide_render:
            continue
        hit = [s for s in o.material_slots if s.material and s.material.name == mat.name]
        if not hit:
            continue
        orig = hit[0].material
        for s in o.material_slots:
            if s.material and s.material.name == orig.name:
                s.material = cp
        bpy.ops.object.select_all(action='DESELECT')
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        try:
            bpy.ops.object.bake(type='EMIT', use_clear=True)
            img.filepath_raw = os.path.join(OUT, clean(mat.name) + ".png")
            img.file_format = 'PNG'
            img.save()
            ok = True
        except Exception as e:
            print("BAKE FAIL", mat.name, e)
        for s in o.material_slots:
            if s.material is cp:
                s.material = orig
        if ok:
            break
    if ok:
        done += 1
        print("BAKED:", mat.name)
    else:
        print("NOT BAKED:", mat.name)

print("DONE", done)
"""#
}
