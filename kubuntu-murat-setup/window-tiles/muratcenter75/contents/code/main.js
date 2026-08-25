// Resize the active window to 75% of the work area and center it.
// Bound to Ctrl+Alt+Enter by window-tiles.sh / registerShortcut.

const SCALE = 0.75;

function center75() {
    const win = workspace.activeWindow;
    if (!win || win.specialWindow || !win.moveable) {
        return;
    }

    if (win.fullScreen) {
        win.fullScreen = false;
    }
    win.setMaximize(false, false);
    if (win.tile) {
        win.tile = null;
    }

    const area = workspace.clientArea(KWin.MaximizeArea, win);
    let w = Math.round(area.width * SCALE);
    let h = Math.round(area.height * SCALE);

    const minW = win.minSize ? win.minSize.width : 0;
    const minH = win.minSize ? win.minSize.height : 0;
    const maxW = win.maxSize ? win.maxSize.width : 0;
    const maxH = win.maxSize ? win.maxSize.height : 0;
    if (minW > 0) {
        w = Math.max(w, minW);
    }
    if (minH > 0) {
        h = Math.max(h, minH);
    }
    // Some clients advertise INT_MAX as maxSize; ignore those.
    if (maxW > 0 && maxW < 100000) {
        w = Math.min(w, maxW);
    }
    if (maxH > 0 && maxH < 100000) {
        h = Math.min(h, maxH);
    }
    if (win.resizeable === false) {
        w = win.width;
        h = win.height;
    }
    w = Math.min(w, area.width);
    h = Math.min(h, area.height);

    const geo = {
        x: Math.round(area.x + (area.width - w) / 2),
        y: Math.round(area.y + (area.height - h) / 2),
        width: w,
        height: h,
    };
    if (typeof Qt !== "undefined" && Qt.rect) {
        win.frameGeometry = Qt.rect(geo.x, geo.y, geo.width, geo.height);
    } else {
        win.frameGeometry = geo;
    }
}

registerShortcut(
    "muratCenter75",
    "Resize window to 75% and center",
    "Ctrl+Alt+Return",
    center75,
);
registerShortcut(
    "muratCenter75Keypad",
    "Resize window to 75% and center (keypad Enter)",
    "Ctrl+Alt+Enter",
    center75,
);
