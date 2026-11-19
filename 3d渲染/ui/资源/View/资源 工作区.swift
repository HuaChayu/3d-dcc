import SwiftUI

/// 模式四：资源。材质库 + 网格库 + 快速分配。
struct AssetWorkspace: View {
    @Environment(着色Store.self) private var store
    @Environment(布局Store.self) private var layout
    @Environment(AppStore.self) private var app
    @State private var query = ""

    private var filteredMaterials: [MaterialAsset] {
        // 只列库里的条目：物体身上那些实例（某个条目用到场景后派生的一份）不进库
        let 库 = store.库材质列表
        guard !query.isEmpty else { return 库 }
        return 库.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            materialsColumn

            Rectangle().fill(Theme.divider).frame(width: 1)

            VStack(spacing: 0) {
                ViewportPanel()
                meshLibraryBar
            }
        }
        .background(Theme.canvasBackground)
    }

    // MARK: 材质库

    private var materialsColumn: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "材质库", symbol: "square.stack.3d.up") {
                HStack(spacing: 6) {
                    Button {
                        store.addMaterial()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)

                    Button {
                        if let id = store.activeMaterialID { store.duplicateMaterial(id) }
                    } label: {
                        Image(systemName: "plus.square.on.square")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                }
            }

            TextField("搜索材质", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredMaterials) { material in
                        materialCard(material)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: "库结构", trailing: "\(store.库材质列表.count) 份")
                Text("每份材质 = OpenPBR 基线参数 + 节点图。绑定到物体后，物体即使用该材质求值结果。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
        }
        .frame(width: 320)
        .background(Theme.panelBackground)
    }

    private func materialCard(_ material: MaterialAsset) -> some View {
        // 库结构里列的是材质原始样式：调参不该让库里的色块跟着变
        let resolved = MaterialCompiler.resolve(material.原始样式)
        let isActive = store.activeMaterialID == material.id
        let usage = store.objectCount(for: material.id)

        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.color(from: resolved.params.previewColor))
                .frame(width: 46, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    if resolved.params.double(.baseMetallic) > 0.5 {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8))
                            .padding(3)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(material.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text(material.note.isEmpty ? "自定义材质" : material.note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    badge("节点 \(material.graph.nodes.count)")
                    badge("使用 \(usage)")
                    if !resolved.drivenKeys.isEmpty {
                        badge("驱动 \(resolved.drivenKeys.count)")
                    }
                }
            }
            Spacer(minLength: 0)

            Menu {
                Button("设为当前材质") {
                    store.selectedMaterialID = material.id
                    app.tab = .shading
                }
                if let object = layout.selectedObject {
                    Button("绑定到 \(object.name)") {
                        // 拿库里的条目绑物体 = 挂它的一份原始样式实例
                        layout.assign(store.实例ID(for: material.id), to: object.id)
                    }
                }
                Button("复制") { store.duplicateMaterial(material.id) }
                // 内置预设不给删（复制出来的副本不算内置，可以删）
                if !material.是内置预设 {
                    Divider()
                    // 这里列的是材质库，删就是删本地那份 .cgmat（进废纸篓，可恢复）
                    Button("从材质库删除（连同本地文件）", role: .destructive) {
                        store.删除库材质(material.id)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Theme.divider)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? Color.accentColor.opacity(0.5) : Theme.divider, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedMaterialID = material.id
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Theme.divider, in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.secondary)
    }

    // MARK: 网格库

    private var meshLibraryBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("网格库")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(MeshKind.allCases) { mesh in
                    Button {
                        // 面板点击 = 当场程序生成真实几何并入池，和下拉菜单、出厂三件套同一套生成器
                        guard let 预设 = 初始项目.预设(for: mesh) else { return }
                        let 物体 = 初始项目.造物体(预设,
                                                材质们: layout.shading?.materials ?? [],
                                                已有: layout.objects)
                        layout.addObject(物体)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: mesh.symbol)
                                .font(.system(size: 10))
                            Text(mesh.title)
                                .font(.system(size: 10))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                Spacer()

                Text("点击即可加入场景")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Theme.panelBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}
