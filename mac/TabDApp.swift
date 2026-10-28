import AppKit
import SwiftUI

@main struct TabDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model:delegate.model, updater:delegate.updater)
        } label: {
            Image(systemName:delegate.model.phase == .paused ? "display.and.arrow.down" : "display")
                .accessibilityLabel("Mr. Tab-D: \(delegate.model.message)")
        }.menuBarExtraStyle(.window)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model=AppModel()
    lazy var updater=AppUpdater(canPrompt:{ [weak self] in self?.model.isBusy == false && NSApp.modalWindow == nil })
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.launch()
        updater.check()
    }
    func applicationWillTerminate(_ notification:Notification) { updater.close(); model.shutdown() }
}

struct MenuPanel: View {
    @ObservedObject var model:AppModel
    @ObservedObject var updater:AppUpdater
    @State private var settings=false
    private let sage=Color(red:0.66,green:0.76,blue:0.65)
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text(settings ? "화면 설정" : "Mr. Tab-D").font(.title3.weight(.semibold))
                Spacer()
                if settings { Button("완료") { settings=false }.buttonStyle(.plain) }
                else {
                    Menu {
                        Button("화면 기록 권한 확인") { model.requestPermission() }
                        Button("클릭 제어 권한 확인") { model.requestInputPermission() }
                        Button("손쉬운 사용 설정 열기…") { model.openInputSettings() }
                        Button("업데이트 확인…") { updater.check(manual:true) }
                        Button("Mr. Tab-D 종료") { NSApp.terminate(nil) }
                    } label:{ Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            if settings {
                Picker("화면 모드",selection:$model.selectedMode) {
                    Text("기본 · 1920×1200").tag(0)
                    Text("원본 해상도 · 3504×2190").tag(1)
                }.pickerStyle(.radioGroup).disabled(model.hasDisplay)
                Toggle("무선 연결 허용",isOn:Binding(get:{ model.allowLAN },set:{ model.setWireless($0) }))
                    .disabled(model.hasDisplay)
                Text("USB를 먼저 사용합니다. 화면 모드는 연결 종료 후 변경할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing:14) {
                    Image(systemName:"ipad.landscape").font(.system(size:34,weight:.light))
                    VStack(alignment:.leading,spacing:4) {
                        Text(model.deviceName).font(.headline)
                        Text(model.route).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing:9) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName:model.phase == .paused ? "pause.circle.fill" : "circle.fill")
                        .foregroundStyle(model.phase == .paused ? Color.orange : model.phase == .streaming ? Color.green : Color.gray)
                        .font(.system(size:11)) }
                    Text(model.message).font(.subheadline)
                }
                if model.phase == .paused {
                    Text("태블릿에서 Mr. Tab-D를 열면 다시 표시합니다")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    if model.hasDisplay || model.isBusy { model.disconnect() } else { model.connect() }
                } label:{
                    Text(model.hasDisplay || model.isBusy ? "연결 종료" : "화면 연결")
                        .frame(maxWidth:.infinity).padding(.vertical,10)
                }.buttonStyle(.plain)
                    .background(model.hasDisplay ? Color.primary.opacity(0.07) : sage)
                    .foregroundStyle(model.hasDisplay ? Color.primary : Color.black)
                    .clipShape(RoundedRectangle(cornerRadius:9))
                    .disabled(!model.hasDisplay && !model.peerConnected)
                Divider()
                Button { settings=true } label:{ Label("화면 설정",systemImage:"gearshape").frame(maxWidth:.infinity,alignment:.leading) }
                Button { model.openDisplaySettings() } label:{ Label("디스플레이 배치…",systemImage:"arrow.up.right.square").frame(maxWidth:.infinity,alignment:.leading) }
            }
            if let error=model.lastError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)
                if model.hasDisplay, !model.isBusy {
                    Button("다시 연결") { model.connect(resuming:true) }
                }
                if !model.hasCapturePermission {
                    Button("화면 기록 설정 열기") { model.openCaptureSettings() }
                }
            }
            if let inputMessage=model.inputMessage {
                Text(inputMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Button("손쉬운 사용 설정 열기") { model.openInputSettings() }
            }
            Divider()
            if updater.busy {
                HStack { ProgressView().controlSize(.small); Text(updater.status ?? "업데이트 확인 중…").font(.caption) }
            }
            Button("업데이트 확인…") { updater.check(manual:true) }.disabled(updater.busy)
            Button("Mr. Tab-D 종료") { NSApp.terminate(nil) }.foregroundStyle(.secondary)
        }.buttonStyle(.plain).padding(20).frame(width:320)
    }
}
