hl.window_rule({
  match = {
    title =
        "(?i)^("
        .. "(?:Abrir(?:\\suna?)?\\s(?:carpeta|archivos?|imagen)(?:\\s.*)?)"
        .. "|"
        .. "Todos los archivos"
        .. ")$"
  },
  tag = "+fileDialog"
})

hl.window_rule({
  match = { tag = "fileDialog" },

  float = true,
  size = "monitor_w*0.7 monitor_h*0.7",
  dim_around = true,
  center = true
})

hl.window_rule({
  name = "Thunar: File Operation",
  match = {
    class = "[Tt]hunar",
    title =
        "^(?:"
        .. "Renombrar\\s.*"
        .. "|Crear una carpeta nueva"
        .. "|Progreso de las operaciones de archivo"
        .. "|Nuev(?:a|o)\\s.*"
        .. ")$"
  },
  float = true,
  center = true,
  dim_around = true,
})
