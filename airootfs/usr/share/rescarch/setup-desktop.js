// KDE Plasma Desktop Configuration Script

// Set wallpaper
var allDesktops = desktops();
for (var i = 0; i < allDesktops.length; i++) {
    var desktop = allDesktops[i];
    desktop.wallpaperPlugin = "org.kde.image";
    desktop.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
    desktop.writeConfig("Image", "file:///usr/share/wallpapers/Flow/");
}

// Configure pinned applications in task manager
var panels = panels();
for (var panelIndex = 0; panelIndex < panels.length; panelIndex++) {
    var panel = panels[panelIndex];
    var widgets = panel.widgets();
    
    for (var widgetIndex = 0; widgetIndex < widgets.length; widgetIndex++) {
        var widget = widgets[widgetIndex];
        
        // Find the icon tasks widget (task manager)
        if (widget.type === "org.kde.plasma.icontasks") {
            widget.currentConfigGroup = ["General"];
            // Set pinned launchers
            widget.writeConfig("launchers", [
                "preferred://terminal",
                "preferred://filemanager",
                "preferred://browser",
                "applications:org.gnome.DiskUtility.desktop"
            ]);
        }
    }
}
