# Material de la charla (rama local `pruebas`)

Esta rama no se sube a GitHub: un hook `pre-push` local la rechaza. Contiene las versiones
originales de los archivos con referencias a la charla y el estado de las pruebas.

| Archivo | Qué es |
|---------|--------|
| `DEMO-SCENARIOS.md` | Notas de ponente originales de `demo-setup/DEMO-SCENARIOS.md` |
| `demo-setup-README.md` | `demo-setup/README.md` original, con el checklist "Check before the talk" |
| `CLAUDE.md` | `CLAUDE.md` original |

- El workspace de las pruebas es `DataSaturday`: en `main` el nombre por defecto es `FabricPerfLab`,
  así que los scripts se lanzan con `-WorkspaceName DataSaturday`.
- Durante la charla, ocultar al agente también esta carpeta:
  `{ "permissions": { "deny": ["Read(demo-setup/**)", "Grep(demo-setup/**)", "Glob(demo-setup/**)", "Read(charla/**)", "Grep(charla/**)", "Glob(charla/**)"] } }`
- `demo-setup/.state/`, `.atl/` y `.vscode/` están versionados aquí con `git add -f`; `informes/`
  entra normal cuando exista.
- Para traer cambios de `main`: `git switch pruebas && git merge main`.
- **No cambiar a `main` en esta carpeta mientras corre `setup.ps1`:** `.state/`, `.atl/` y `.vscode/`
  solo están versionados en `pruebas`, así que `git switch main` los borra del disco y el script
  escribiría en un estado que ya no existe. Para editar `main`, usa un worktree aparte:
  `git worktree add ../fabric-perf-analyst-main main`.
