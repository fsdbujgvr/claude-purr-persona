# claude-rp-seed.ps1
# Mint a seed transcript for claude-rp by running a REAL headless `claude -p` prime,
# then rewriting it into the persona's opening conversation. Because the prime
# is a genuine Claude Code run, the records carry the *current* model and the
# authentic field layout for this Claude version -- no hardcoded / guessed model.
#
# Flow:
#   1. Run `claude -p <prompt> --output-format json` in $Cwd (retry up to 3x on
#      transient failure) and extract session_id. No MCP is attached -- the
#      prime only mints records; MCP belongs to the real session that claude-rp
#      launches afterward via --resume.
#   2. Locate the generated <sid>.jsonl and pull the real user + assistant
#      records out as templates.
#   3. Rebuild the file as one user+assistant pair per opening turn (dialog
#      only, no meta/permission-mode header). The first pair reuses the real
#      records (text swapped); extra turns are cloned from them as plain dialog.
#   4. Everything else the prime wrote is dropped: queue-operation
#      (enqueue/dequeue), the attachment records (deferred_tools_delta /
#      skill_listing) and last-prompt. The attachments only bloat context and
#      Claude re-injects the live skill/tool listing on launch anyway; the
#      queue/last-prompt records would otherwise leak the throwaway prime prompt
#      (last-prompt makes the Up-arrow recall it).
#   5. Print the session id for claude-rp.cmd to --resume.
#
# Opening file (persona.opening.json) accepts either a single turn:
#     {"user":"...","assistant":"..."}
#   or multiple turns:
#     {"turns":[{"user":"...","assistant":"..."}, ...]}
#
# Each turn may ALSO carry an optional "system" string. When present, it is
# emitted as a `mid_conv_system` content block appended (as the required last
# block) to that turn's user message -- the API form of a mid-conversation
# system instruction. It SUPPLEMENTS the top-level system prompt (persona.md via
# --system-prompt-file); it does not replace it. Note: Opus 4.8 treats a
# system instruction injected into resumed history as low-authority (it may
# decline to act on it and even remark that it "did not come from you"), so
# this is a format capability, not a reliable behavior lever. Leave "system"
# absent/empty to get the previous plain-string user content unchanged.
#
# No fallback: if the prime fails the script errors out (prints nothing to
# stdout, diagnostics to stderr) so claude-rp does not seed.

param(
    [string]$Cwd = (Get-Location).Path,
    [string]$OpeningFile = "$env:USERPROFILE\.claude\personas\persona.opening.json"
)

$ErrorActionPreference = 'Stop'

function New-Token([string]$prefix, [int]$len) {
    $chars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    $s = -join (1..$len | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    "$prefix$s"
}

try {
    # --- 1. Read & normalize the opening into a list of {user, assistant} turns.
    $opening = Get-Content $OpeningFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $turns = @()
    if (($opening.PSObject.Properties.Name -contains 'turns') -and $opening.turns) {
        foreach ($t in $opening.turns) {
            $turns += [pscustomobject]@{ user = [string]$t.user; assistant = [string]$t.assistant; system = [string]$t.system }
        }
    } else {
        $turns += [pscustomobject]@{ user = [string]$opening.user; assistant = [string]$opening.assistant; system = [string]$opening.system }
    }
    if ($turns.Count -lt 1 -or [string]::IsNullOrEmpty($turns[0].user)) {
        throw "opening file has no usable turns: $OpeningFile"
    }

    # --- 2. Real prime: run headless claude in the project cwd (no MCP). Retry
    #        a few times -- the prime occasionally fails on a transient backend
    #        blip or a stray non-JSON notice line on stdout ("sometimes works,
    #        sometimes not" is exactly that). Each attempt:
    #          * runs via cmd so stdin is redirected from NUL (claude -p waits on
    #            stdin when spawned non-interactively, e.g. inside cmd's for /f,
    #            and PowerShell has no `< NUL` operator);
    #          * captures claude's stderr to a temp file so a real failure is
    #            reported, not swallowed;
    #          * extracts session_id by regex, so a prepended notice/tip line
    #            does not break parsing.
    [Console]::Error.WriteLine("[claude-rp-seed] priming a real session (claude -p, ~3s)...")
    $sid = $null
    $lastDiag = ''
    $primeSids = @()   # every session id minted by a prime attempt this run
    Push-Location $Cwd
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $errf = [System.IO.Path]::GetTempFileName()
            $primeOut = ''
            try { $primeOut = [string](& cmd /c "claude -p `"ping`" --output-format json <NUL 2>`"$errf`"" | Out-String) } catch { $primeOut = '' }
            $errTxt = ''
            if (Test-Path $errf) { $errTxt = [string](Get-Content $errf -Raw -ErrorAction SilentlyContinue) }
            Remove-Item $errf -ErrorAction SilentlyContinue
            if ($primeOut -match '"session_id"\s*:\s*"([^"]+)"') {
                $cand = $matches[1]
                $primeSids += $cand
                if ($primeOut -notmatch '"is_error"\s*:\s*true') { $sid = $cand; break }
            }
            $lastDiag = ($errTxt + ' ' + $primeOut).Trim()
            [Console]::Error.WriteLine("[claude-rp-seed] prime attempt $attempt failed; retrying...")
            if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
        }
    } finally {
        Pop-Location
    }

    $root = Join-Path $env:USERPROFILE ".claude\projects"
    $encoded = ($Cwd -replace '[^A-Za-z0-9]', '-')
    $projDir = Join-Path $root $encoded

    # Clean up this run's own throwaway prime sessions: every failed/retried
    # attempt left a 'ping' transcript we don't use. Deleted by the exact
    # session ids we minted -- no scanning, no tags, no guessing. The accepted
    # $sid is kept (it becomes the seed below); on total failure $sid is empty
    # so every minted prime session is removed.
    foreach ($psid in ($primeSids | Select-Object -Unique)) {
        if ($psid -ne $sid) {
            $jf = Join-Path $projDir "$psid.jsonl"
            if (Test-Path $jf) { Remove-Item $jf -Force -ErrorAction SilentlyContinue }
        }
    }

    if ([string]::IsNullOrEmpty($sid)) {
        $tail = $lastDiag; if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) }
        throw "prime failed after 3 attempts (no session_id). last claude output: $tail"
    }

    # --- 3. Locate the transcript the prime just wrote.
    $file = Join-Path $projDir "$sid.jsonl"
    if (-not (Test-Path $file)) {
        $hit = Get-ChildItem $root -Recurse -Filter "$sid.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $file = $hit.FullName } else { throw "prime transcript not found for session $sid" }
    }

    # --- 4. Pull the real user + assistant records out as templates (raw JSON lines).
    $userTplJson = $null; $asstTplJson = $null
    foreach ($ln in (Get-Content $file -Encoding UTF8)) {
        if (-not $ln.Trim()) { continue }
        $r = $null; try { $r = $ln | ConvertFrom-Json } catch { continue }
        if ((-not $userTplJson) -and $r.type -eq 'user' -and $r.message.role -eq 'user') { $userTplJson = $ln }
        elseif ((-not $asstTplJson) -and $r.type -eq 'assistant') { $asstTplJson = $ln }
        if ($userTplJson -and $asstTplJson) { break }
    }
    if ((-not $userTplJson) -or (-not $asstTplJson)) { throw "prime transcript missing user/assistant record" }

    # --- 5. Rebuild: one user/assistant pair per opening turn (dialog only).
    $out = New-Object System.Collections.Generic.List[string]

    $baseTime = (Get-Date).ToUniversalTime()
    $seq = 0
    $prevAsstUuid = $null
    for ($i = 0; $i -lt $turns.Count; $i++) {
        $uUuid = [guid]::NewGuid().ToString()
        $aUuid = [guid]::NewGuid().ToString()

        # user record (clone of the real one; its content is a plain string)
        $u = $userTplJson | ConvertFrom-Json
        $u.uuid = $uUuid
        $u.parentUuid = $prevAsstUuid
        if ($u.PSObject.Properties.Name -contains 'promptId')   { $u.promptId = [guid]::NewGuid().ToString() }
        if ($u.PSObject.Properties.Name -contains 'entrypoint') { $u.entrypoint = 'cli' }
        $u.timestamp = $baseTime.AddSeconds($seq).ToString("yyyy-MM-ddTHH:mm:ss.fffZ"); $seq++
        if (-not [string]::IsNullOrEmpty($turns[$i].system)) {
            # Optional mid-conversation system instruction for this turn. The
            # API requires the mid_conv_system block to be the LAST block in the
            # turn, so content = [ <user text>, <mid_conv_system> ]. Build via a
            # sentinel + literal splice (same PS 5.1 array-collapse workaround as
            # the assistant block below).
            $u.message.content = "@@RP_USER@@"
            $uLine = $u | ConvertTo-Json -Compress -Depth 30
            $userBlk = [ordered]@{ type = "text"; text = $turns[$i].user } | ConvertTo-Json -Compress
            $sysInner = [ordered]@{ type = "text"; text = $turns[$i].system } | ConvertTo-Json -Compress
            $sysBlk = '{"type":"mid_conv_system","content":[' + $sysInner + ']}'
            $uLine = $uLine.Replace('"@@RP_USER@@"', "[$userBlk,$sysBlk]")
            [void]$out.Add($uLine)
        } else {
            $u.message.content = $turns[$i].user
            [void]$out.Add(($u | ConvertTo-Json -Compress -Depth 30))
        }

        # assistant record (clone; keep the real model, minimal usage, inject text)
        $a = $asstTplJson | ConvertFrom-Json
        $a.uuid = $aUuid
        $a.parentUuid = $uUuid
        if ($a.PSObject.Properties.Name -contains 'requestId')  { $a.requestId = New-Token "req_" 24 }
        if ($a.PSObject.Properties.Name -contains 'entrypoint') { $a.entrypoint = 'cli' }
        $a.timestamp = $baseTime.AddSeconds($seq).ToString("yyyy-MM-ddTHH:mm:ss.fffZ"); $seq++
        $a.message.id = New-Token "msg_" 24
        $a.message.usage = [ordered]@{ input_tokens = 1; output_tokens = 1; service_tier = "standard" }
        # Set content to a unique sentinel string, then splice in a proper
        # one-element block array -- sidesteps PS 5.1 collapsing single-element
        # arrays into objects.
        $a.message.content = "@@RP_CONTENT@@"
        $aLine = $a | ConvertTo-Json -Compress -Depth 30
        $block = [ordered]@{ type = "text"; text = $turns[$i].assistant } | ConvertTo-Json -Compress
        $aLine = $aLine.Replace('"@@RP_CONTENT@@"', "[$block]")
        [void]$out.Add($aLine)

        $prevAsstUuid = $aUuid
    }

    # --- 6. Overwrite the transcript with our rebuilt opening (UTF-8, no BOM).
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($file, $out, $utf8NoBom)

    # --- 7. Emit the session id for claude-rp.cmd to capture and --resume.
    Write-Output $sid
}
catch {
    [Console]::Error.WriteLine("[claude-rp-seed] $($_.Exception.Message)")
    exit 1
}
