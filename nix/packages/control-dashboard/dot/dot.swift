import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4, args[0] == "--server", args[2] == "--open",
      let server = URL(string: args[1].replacingOccurrences(of: "http", with: "ws", options: .anchored))
else {
  FileHandle.standardError.write("usage: control-dashboard-dot --server URL --open CMD...\n".data(using: .utf8)!)
  exit(2)
}

func dot(_ color: NSColor?) -> NSImage {
  NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
    let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
    if let color {
      color.setFill()
      circle.fill()
    } else {
      NSColor.gray.setStroke()
      circle.lineWidth = 1.5
      circle.stroke()
    }
    return true
  }
}

final class Dot: NSObject {
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  let menu = NSMenu()
  let server: URL
  let command: [String]

  init(server: URL, command: [String]) {
    self.server = server
    self.command = command
    super.init()
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.button?.target = self
    item.button?.action = #selector(click)
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    show(nil)
    connect()
  }

  func show(_ status: String?) {
    item.isVisible = status != "fine"
    switch status {
    case "bad": item.button?.image = dot(NSColor(red: 0.75, green: 0.2, blue: 0.2, alpha: 1))
    case "waiting": item.button?.image = dot(NSColor(red: 0.75, green: 0.55, blue: 0.1, alpha: 1))
    default: item.button?.image = dot(nil)
    }
  }

  func connect() {
    let task = URLSession.shared.webSocketTask(with: server)
    task.resume()
    receive(task)
  }

  func receive(_ task: URLSessionWebSocketTask) {
    task.receive { result in
      DispatchQueue.main.async {
        guard case .success(let message) = result else {
          task.cancel()
          self.show(nil)
          DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.connect() }
          return
        }
        let data: Data?
        switch message {
        case .string(let s): data = s.data(using: .utf8)
        case .data(let d): data = d
        @unknown default: data = nil
        }
        let view = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        self.show(view?["status"] as? String)
        self.receive(task)
      }
    }
  }

  @objc func click() {
    if NSApp.currentEvent?.type == .rightMouseUp {
      item.menu = menu
      item.button?.performClick(nil)
      item.menu = nil
    } else {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = command
      try? process.run()
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let theDot = Dot(server: server, command: Array(args[3...]))
app.run()
