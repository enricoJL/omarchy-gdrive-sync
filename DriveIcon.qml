import QtQuick
import QtQuick.Shapes
import qs.Commons

// Google Drive triangle drawn as a ring, with an optional status dot.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color dotColor: "transparent"
  property bool dotVisible: false

  width: iconSize * 1.1
  height: iconSize
  implicitWidth: width
  implicitHeight: height

  Shape {
    id: shape
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4

    readonly property real w: root.width
    readonly property real h: root.height
    readonly property real inset: 0.30

    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      fillRule: ShapePath.OddEvenFill

      startX: shape.w * 0.5; startY: shape.h * 0.02
      PathLine { x: shape.w * 0.98; y: shape.h * 0.92 }
      PathLine { x: shape.w * 0.02; y: shape.h * 0.92 }
      PathLine { x: shape.w * 0.5; y: shape.h * 0.02 }

      PathMove { x: shape.w * 0.5; y: shape.h * 0.38 }
      PathLine { x: shape.w * 0.30; y: shape.h * 0.74 }
      PathLine { x: shape.w * 0.70; y: shape.h * 0.74 }
      PathLine { x: shape.w * 0.5; y: shape.h * 0.38 }
    }
  }

  Rectangle {
    visible: root.dotVisible
    width: Math.max(4, root.iconSize * 0.42)
    height: width
    radius: width / 2
    color: root.dotColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: -width * 0.25
    anchors.bottomMargin: -height * 0.1
    border.width: 1
    border.color: Color.bar.background
  }
}
