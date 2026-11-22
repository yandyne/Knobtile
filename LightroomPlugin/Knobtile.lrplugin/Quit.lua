local LrTasks = import 'LrTasks'
return {
  LrShutdownFunction = function(done)
    local prefs = import 'LrPrefs'.prefsForPlugin()
    prefs.gen = (prefs.gen or 0) + 1
    LrTasks.startAsyncTask(function()
      LrTasks.sleep(0.5) -- one loop period: the sockets are closed before Lightroom quits
      done()
    end)
  end,
}
