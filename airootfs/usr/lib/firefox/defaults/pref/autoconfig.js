// Disable first-run pages and configure homepage
pref("browser.startup.homepage", "https://wiki.archlinux.org/title/Installation_guide");
pref("browser.startup.page", 1);
pref("browser.startup.homepage_override.mstone", "ignore");
pref("startup.homepage_welcome_url", "");
pref("startup.homepage_welcome_url.additional", "");
pref("startup.homepage_override_url", "");
pref("browser.newtabpage.enabled", false);
pref("browser.newtab.preload", false);
pref("browser.aboutwelcome.enabled", false);
pref("trailhead.firstrun.didSeeAboutWelcome", true);

// Enable dark mode
pref("extensions.activeThemeID", "firefox-compact-dark@mozilla.org");
pref("ui.systemUsesDarkTheme", 1);
pref("browser.theme.toolbar-theme", 0);
pref("browser.theme.content-theme", 0);
pref("browser.in-content.dark-mode", true);
pref("ui.prefersReducedMotion", 0);

// Disable AI features
pref("browser.ml.chat.enabled", false);
pref("browser.ml.chat.sidebar", false);
pref("browser.ml.enable", false);
pref("browser.ml.chat.provider", "");
pref("browser.translations.enable", false);
pref("browser.translations.automaticallyPopup", false);

// Disable telemetry and data collection
pref("datareporting.healthreport.uploadEnabled", false);
pref("datareporting.policy.dataSubmissionEnabled", false);
pref("toolkit.telemetry.enabled", false);
pref("toolkit.telemetry.unified", false);
pref("toolkit.telemetry.archive.enabled", false);
pref("toolkit.telemetry.server", "");
pref("toolkit.telemetry.coverage.opt-out", true);
pref("toolkit.coverage.opt-out", true);
pref("toolkit.coverage.endpoint.base", "");

// Disable Firefox Studies and experiments
pref("app.shield.optoutstudies.enabled", false);
pref("app.normandy.enabled", false);
pref("app.normandy.api_url", "");

// Disable Firefox Accounts and Sync
pref("identity.fxaccounts.enabled", false);
pref("browser.aboutwelcome.enabled", false);

// Disable Pocket
pref("extensions.pocket.enabled", false);
pref("extensions.pocket.api", "");
pref("extensions.pocket.site", "");

// Disable tips, recommendations, and suggestions
pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);
pref("browser.newtabpage.activity-stream.feeds.snippets", false);
pref("browser.newtabpage.activity-stream.section.highlights.includePocket", false);
pref("browser.newtabpage.activity-stream.showSponsored", false);
pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons", false);
pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features", false);
pref("browser.messaging-system.whatsNewPanel.enabled", false);
pref("browser.urlbar.suggest.quicksuggest.sponsored", false);
pref("browser.urlbar.suggest.quicksuggest.nonsponsored", false);
pref("browser.urlbar.quicksuggest.enabled", false);

// Disable more from Mozilla
pref("browser.preferences.moreFromMozilla", false);

// Disable crash reports
pref("breakpad.reportURL", "");
pref("browser.tabs.crashReporting.sendReport", false);
pref("browser.crashReports.unsubmittedCheck.enabled", false);
pref("browser.crashReports.unsubmittedCheck.autoSubmit2", false);

// Disable screenshot tool
pref("extensions.screenshots.disabled", true);

// Disable form autofill
pref("extensions.formautofill.addresses.enabled", false);
pref("extensions.formautofill.creditCards.enabled", false);

// Disable password manager prompts (optional - user can still use it manually)
pref("signon.rememberSignons", false);
pref("signon.autofillForms", false);
pref("signon.generation.enabled", false);

// Disable PDF.js assistant
pref("pdfjs.enableScripting", false);
