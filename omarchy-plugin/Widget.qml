import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button for the BeeModel window. The modeler stays a real window;
// this only focuses it or starts it.
BarWidget {
  id: root
  moduleName: "bart.beemodel"

  function pluginFile(name) {
    var url = Qt.resolvedUrl(name).toString()
    if (url.indexOf("file://") === 0)
      url = url.slice(7)
    return decodeURIComponent(url)
  }

  function binaryPath() {
    var custom = String(setting("binary", "") || "")
    if (custom !== "")
      return custom
    var home = String(Quickshell.env("HOME") || "")
    return home + "/.local/bin/beemodel"
  }

  function openApp() {
    var argv = [pluginFile("launch.sh"), binaryPath()]
    var scene = String(setting("scene", "") || "")
    if (scene !== "")
      argv.push(scene)
    Util.execArgv(argv)
  }

  IpcHandler {
    target: "bart.beemodel"

    function app(): string {
      root.openApp()
      return "ok"
    }

    function open(): string {
      root.openApp()
      return "ok"
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰆧"
    tooltipText: "BeeModel"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton)
        root.openApp()
    }
  }
}
