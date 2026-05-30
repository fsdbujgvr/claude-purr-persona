任务：在我的 Windows 电脑上部署一个新命令 `claude-rp`——在官方 Claude Code CLI（命令
`claude`）基础上的启动包装器。它做两件事，且不影响原版 `claude`：
  (A) 注入人格：把 persona.md 作为系统提示词注入；
  (B) 注入开场：启动前真跑一次 `claude -p` 生成真实会话记录，把问答文本换成 persona.opening.json
      里的开场对话，再 `--resume` 它，让角色一打开就在状态里。

本包附带 4 个**已脱敏、可直接用**的文件，**逐字照抄**部署即可，不要改写逻辑：
  - bin/claude-rp.cmd
  - bin/claude-rp-seed.ps1
  - personas/persona.md
  - personas/persona.opening.json

【部署】放到 `%USERPROFILE%\.claude\` 下，保持目录结构：
  %USERPROFILE%\.claude\bin\claude-rp.cmd
  %USERPROFILE%\.claude\bin\claude-rp-seed.ps1
  %USERPROFILE%\.claude\personas\persona.md
  %USERPROFILE%\.claude\personas\persona.opening.json
确保 `%USERPROFILE%\.claude\bin` 在 PATH，且 `claude -p "x" --output-format json` 能跑通。

【常用开关】
  claude-rp            人格 + 开场
  claude-rp -noseed    只人格，不预热（更快、不计费）
  claude-rp -append    人格用追加模式（默认是完全替换）
  claude-rp -persona X 改用 personas\X.md + personas\X.opening.json
  其余参数原样透传给 claude。

【自定义】改人格编辑 persona.md；改开场编辑 persona.opening.json（支持单轮或多轮 turns，
每轮可选 system 字段注入场景设定）。

【测试】真实终端里跑 `claude-rp`，应出现 injecting persona / priming / seeded opening 三行，
聊天框出现开场气泡。出错先用 `claude-rp -noseed` 兜底。
