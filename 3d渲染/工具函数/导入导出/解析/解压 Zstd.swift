//
//  解压 Zstd.swift
//  3d渲染
//
//  内嵌 zstd 解压（C 源码在 工具函数/导入导出/zstd，经 PT-Bridging-Header.h 暴露）。
//  只做解压不做压缩：Blender 保存时可勾「Compress」，整个 .blend 会被包成 zstd 帧，
//  要读它就得先把壳脱掉。App 自己不写 .blend，所以不需要压缩方向。
//

import Foundation

enum Zstd {

    /// zstd 帧魔数 0x28 B5 2F FD
    static func 是压缩数据(_ 数据: [UInt8]) -> Bool {
        数据.count >= 4
            && 数据[0] == 0x28
            && 数据[1] == 0xB5
            && 数据[2] == 0x2F
            && 数据[3] == 0xFD
    }

    /// 解压整包数据。容量先按帧头声明的大小走，声明不明确时逐级放大重试。
    static func 解压(_ 输入: [UInt8]) throws -> [UInt8] {
        guard !输入.isEmpty else { return [] }

        // Blender 是流式压缩落盘的，帧头声明的 content size 往往只覆盖开头一段
        // （实测第一集.blend 头里写 38465，实际解出 1272369），所以**不能**直接信它。
        // 起步按壳的 24 倍给，再拿帧头声明值兜底取大者，不够就翻倍重试。
        let 帧大小 = 输入.withUnsafeBytes { 缓冲 -> UInt64 in
            guard let p = 缓冲.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return ZSTD_getFrameContentSize(p, 输入.count)
        }
        var 目标 = max(输入.count * 24, 1 << 20)
        // 0xFFFF...FE = 出错，0xFFFF...FF = 未声明
        if 帧大小 != UInt64.max, 帧大小 <= UInt64(Int.max), Int(帧大小) > 目标 {
            目标 = Int(帧大小)
        }

        while true {
            var 输出 = [UInt8](repeating: 0, count: 目标)
            let 结果 = 输入.withUnsafeBytes { 入 in
                输出.withUnsafeMutableBytes { 出 -> Int in
                    guard let 入址 = 入.baseAddress, let 出址 = 出.baseAddress else { return -1 }
                    return ZSTD_decompress(出址, 目标, 入址, 输入.count)
                }
            }

            if ZSTD_isError(结果) != 0 {
                let 名 = String(cString: ZSTD_getErrorName(结果))
                // 缓冲区不够就放大再试一次
                if 名.lowercased().contains("too small") || 名.lowercased().contains("small") {
                    guard 目标 < (1 << 31) else {
                        throw 导入导出错误.解析失败(格式: "BLEND", 原因: "Zstd 解压目标过大：\(名)")
                    }
                    目标 *= 4
                    continue
                }
                throw 导入导出错误.解析失败(格式: "BLEND", 原因: "Zstd 解压失败：\(名)")
            }

            if 结果 < 输出.count {
                输出.removeLast(输出.count - 结果)
            }
            return 输出
        }
    }
}
