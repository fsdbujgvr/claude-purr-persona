@echo off
rem --- Claude Code persona launcher (claude + persona + seeded opening) ----
rem Usage:
rem   claude-rp              claude + persona(persona.md) + seeded opening, no MCP
rem   claude-rp -db          + Postgres MCP Pro
rem   claude-rp -pw          + Playwright MCP
rem   claude-rp -cf          + Comfy Pilot
rem   claude-rp -db -pw      multiple MCP servers
rem   claude-rp -strict      only use specified MCP configs, ignore others
rem   claude-rp -global      force global MCP config, skip per-project override
rem   claude-rp -persona X   use personas\X.md (+ personas\X.opening.json)
rem   claude-rp -noseed      skip the fake opening conversation (persona only)
rem   claude-rp -append      APPEND persona to Claude Code's default system prompt
rem                          (default is FULL REPLACE; see "Persona inject mode")
rem   extra args are passed through to claude
rem
rem Persona inject mode:
rem   default  --system-prompt-file        persona.md REPLACES the entire default
rem                                         system prompt (pure persona, but
rem                                         drops Claude's tool/env/safety text)
rem   -append  --append-system-prompt-file  persona.md is ADDED after the default
rem                                         system prompt (persona + Claude's
rem                                         built-in rules both apply)
rem
rem Files (under %USERPROFILE%\.claude\personas):
rem   persona.md            persona text injected per the mode above
rem   persona.opening.json  the fake user->assistant opening that is pre-seeded
rem                         into a fresh session, then resumed so it shows up in
rem                         the transcript. Edit "user"/"assistant" to taste.
rem Only claude-rp does this; cx / claude are unaffected.
rem ------------------------------------------------------------------------
setlocal enabledelayedexpansion
set "GLOBAL_DIR=%USERPROFILE%\.claude\mcp"
set "LOCAL_DIR=%CD%\.claude\mcp"
set "PERSONA_DIR=%USERPROFILE%\.claude\personas"
set "SEED=%~dp0claude-rp-seed.ps1"
set "PERSONA_NAME=persona"
set "CONFIGS="
set "STRICT="
set "FORCE_GLOBAL="
set "NOSEED="
set "SPMODE=full"
set "PASSARGS="

rem First pass: detect -global so we know which path to pick for -db / -pw
for %%A in (%*) do (
    if /i "%%~A"=="-global" set "FORCE_GLOBAL=1"
)

:parse
if "%~1"=="" goto run
if /i "%~1"=="-db" (
    call :pick postgres-pro.json
    shift
    goto parse
)
if /i "%~1"=="-pw" (
    call :pick playwright.json
    shift
    goto parse
)
if /i "%~1"=="-cf" (
    call :pick comfy-pilot.json
    shift
    goto parse
)
if /i "%~1"=="-strict" (
    set "STRICT=--strict-mcp-config"
    shift
    goto parse
)
if /i "%~1"=="-global" (
    rem already handled in first pass
    shift
    goto parse
)
if /i "%~1"=="-persona" (
    set "PERSONA_NAME=%~2"
    shift
    shift
    goto parse
)
if /i "%~1"=="-noseed" (
    set "NOSEED=1"
    shift
    goto parse
)
if /i "%~1"=="-append" (
    set "SPMODE=append"
    shift
    goto parse
)
set PASSARGS=!PASSARGS! %1
shift
goto parse

:pick
set "NAME=%~1"
if not defined FORCE_GLOBAL if exist "!LOCAL_DIR!\!NAME!" (
    echo [claude-rp] using project-local !NAME! -^> !LOCAL_DIR!\!NAME!
    set CONFIGS=!CONFIGS! "!LOCAL_DIR!\!NAME!"
    exit /b
)
set CONFIGS=!CONFIGS! "!GLOBAL_DIR!\!NAME!"
exit /b

:run
set "PERSONA=!PERSONA_DIR!\!PERSONA_NAME!.md"
set "OPENING=!PERSONA_DIR!\!PERSONA_NAME!.opening.json"
set "APPEND="
if exist "!PERSONA!" (
    if /i "!SPMODE!"=="append" (
        echo [claude-rp] injecting persona APPEND mode -^> !PERSONA!
        set APPEND=--append-system-prompt-file "!PERSONA!"
    ) else (
        echo [claude-rp] injecting persona FULL system prompt -^> !PERSONA!
        set APPEND=--system-prompt-file "!PERSONA!"
    )
) else (
    echo [claude-rp] WARNING persona file not found: !PERSONA!
)

rem --- seed a fake opening conversation, then resume it ---
set "RESUME="
if not defined NOSEED if exist "!OPENING!" if exist "!SEED!" (
    set "SID="
    for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -File "!SEED!" -Cwd "%CD%" -OpeningFile "!OPENING!"`) do set "SID=%%i"
    if defined SID (
        echo [claude-rp] seeded opening -^> session !SID!
        set "RESUME=--resume !SID!"
    ) else (
        echo [claude-rp] WARNING failed to seed opening, launching fresh.
    )
)

if defined CONFIGS (
    call claude --mcp-config!CONFIGS! !STRICT! !RESUME! !APPEND!!PASSARGS!
) else (
    call claude !RESUME! !APPEND!!PASSARGS!
)
endlocal
