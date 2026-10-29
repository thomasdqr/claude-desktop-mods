// My Mod: one line on what it does.
function activate(api) {
  if (api.settings.bold) {
    api.css(`[data-group-name] { font-weight: 700 !important; }`);
  }
  api.watch(() => {
    for (const section of api.sidebar.sections()) {
      // Runs once per frame after Claude's page changes. Mark what you change with your
      // own data attributes, and remove them in api.onCleanup.
    }
  });
}
