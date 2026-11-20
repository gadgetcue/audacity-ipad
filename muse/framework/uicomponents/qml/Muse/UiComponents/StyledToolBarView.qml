/*
 * SPDX-License-Identifier: GPL-3.0-only
 * MuseScore-CLA-applies
 *
 * MuseScore Studio
 * Music Composition & Notation
 *
 * Copyright (C) 2021 MuseScore Limited and others
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 3 as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

pragma ComponentBehavior: Bound

import QtQuick

import Muse.Ui
import Muse.UiComponents

Item {
    id: root

    property alias model: repeater.model

    property alias spacing: content.spacing

    property int leftPadding: 0
    property int rightPadding: 0
    property int topPadding: 0
    property int bottomPadding: 0

    property int rowHeight: 32
    property int separatorHeight: rowHeight

    property bool useSpacersAsSeparators: false
    property int spacerWidth: 12

    property int maximumWidth: -1
    property bool isMultiline: height > rowHeight

    property NavigationPanel navigationPanel: NavigationPanel {
        name: root.objectName !== "" ? root.objectName : "ToolBarView"
        enabled: root.enabled && root.visible

        accessible.name: "ToolBar"
        accessible.visualItem: root
    }

    property var sourceComponentCallback

    // Pill toolbar: every run of items between separators floats in one rounded capsule
    property bool pillStyle: true
    property int pillHeight: 34
    property int pillPadding: 3
    property int layoutRevision: 0

    readonly property color pillFill: ui.theme.isDark ? "#2C2D33" : "#FFFFFF"
    readonly property color pillLine: ui.theme.isDark ? "#3A3C43" : Qt.rgba(0, 0, 0, 0.078)
    readonly property color pillShadow: ui.theme.isDark ? Qt.rgba(0, 0, 0, 0.275) : Qt.rgba(0, 0, 0, 0.094)

    function isSeparatorAt(i) {
        void root.layoutRevision
        if (i < 0 || i >= repeater.count) {
            return true
        }
        var d = repeater.itemAt(i)
        return !d || !d.item || d.item.type === ToolBarItemType.SEPARATOR
    }

    function groupWidthFrom(i) {
        void root.layoutRevision
        var w = 0
        for (var j = i; j < repeater.count && !isSeparatorAt(j); ++j) {
            if (j > i) {
                w += content.spacing
            }
            var d = repeater.itemAt(j)
            w += d ? d.width : 0
        }
        return w
    }

    width: content.width + leftPadding + rightPadding + (pillStyle ? 2 * pillPadding : 0)
    height: content.height + topPadding + bottomPadding

    Component.onCompleted: {
        if (root.model) {
            root.model.load()
        }
    }

    Flow {
        id: content

        anchors.left: root.left
        anchors.leftMargin: root.leftPadding + (root.pillStyle ? root.pillPadding : 0)
        anchors.top: root.top
        anchors.topMargin: root.topPadding

        width: {
            if (root.model.length === 0) {
                return 0
            }

            var result = 0
            var children = content.children

            for (var i = 0; i < children.length; ++i) {
                result += children[i].width + spacing
            }

            if (result > 0) {
                result -= spacing
            }

            return root.maximumWidth !== -1 ? Math.min(result, root.maximumWidth) : result
        }
        height: childrenRect.height

        clip: !root.pillStyle
        spacing: 4

        Repeater {
            id: repeater

            onItemAdded: root.layoutRevision++
            onItemRemoved: root.layoutRevision++

            Item {
                id: delegateItem

                required property ToolBarItem item
                required property int index

                width: loader.width
                height: root.rowHeight

                readonly property bool startsPill: root.pillStyle
                                                   && !root.isSeparatorAt(delegateItem.index)
                                                   && root.isSeparatorAt(delegateItem.index - 1)

                onWidthChanged: root.layoutRevision++

                // soft shadow (0 1px 4px), drawn as a 1px-offset halo
                Rectangle {
                    visible: delegateItem.startsPill
                    z: -2
                    x: -root.pillPadding
                    y: (parent.height - root.pillHeight) / 2 + 1
                    width: root.groupWidthFrom(delegateItem.index) + 2 * root.pillPadding
                    height: root.pillHeight
                    radius: height / 2
                    color: root.pillShadow
                    opacity: 0.6
                }

                Rectangle {
                    visible: delegateItem.startsPill
                    z: -1
                    x: -root.pillPadding
                    y: (parent.height - root.pillHeight) / 2
                    width: root.groupWidthFrom(delegateItem.index) + 2 * root.pillPadding
                    height: root.pillHeight
                    radius: height / 2
                    color: root.pillFill
                    border.width: 1
                    border.color: root.pillLine
                }

                Loader {
                    id: loader

                    property int itemIndex: delegateItem.index

                    anchors.verticalCenter: parent.verticalCenter

                    sourceComponent: {
                        if (!Boolean(delegateItem.item)) {
                            return null
                        }

                        var type = delegateItem.item.type
                        var comp = Boolean(root.sourceComponentCallback) ? root.sourceComponentCallback(type) : null
                        if (Boolean(comp)) {
                            return comp
                        }

                        switch(type) {
                        case ToolBarItemType.ACTION: return actionComp
                        case ToolBarItemType.SEPARATOR: return root.useSpacersAsSeparators ? spacerComp : separatorComp
                        }

                        return null
                    }

                    onLoaded: {
                        loader.item.itemData = delegateItem.item

                        if (Boolean(loader.item.navigation)) {
                            loader.item.navigation.panel = root.navigationPanel
                            loader.item.navigation.row = -1
                            loader.item.navigation.column = delegateItem.index * 100
                        }
                    }

                    Component {
                        id: separatorComp

                        SeparatorLine {
                            property var itemData: delegateItem.item

                            width: 1
                            height: root.separatorHeight

                            orientation: Qt.Vertical
                        }
                    }

                    Component {
                        id: spacerComp

                        Item {
                            property var itemData: delegateItem.item

                            width: root.spacerWidth
                            height: root.separatorHeight
                        }
                    }

                    Component {
                        id: actionComp

                        StyledToolBarItem {
                            itemData: delegateItem.item
                        }
                    }
                }
            }
        }
    }
}
