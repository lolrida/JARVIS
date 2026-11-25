# JARVIS - installazione automatica per Windows
#
# Apri PowerShell e incolla:
#   irm https://raw.githubusercontent.com/lolrida/JARVIS/claude/custom-ai-hosting-platform-z6h61i/install-windows.ps1 | iex
#
# Cosa fa (puoi rilanciarlo quando vuoi: aggiorna JARVIS senza perdere modelli, chiavi o dati):
#   1. installa/avvia Docker Desktop        5. apre la porta 8000 per l'iPhone (rete privata)
#   2. scarica JARVIS                       6. scarica un modello iniziale e crea il tuo modello "jarvis"
#   3. avvia JARVIS (24/7, riparte da solo) 7. scarica l'app iPhone (JARVIS.ipa) sul Desktop
#   4. crea le tue chiavi di accesso        8. salva tutte le credenziali in un file sul Desktop

function Install-Jarvis {
    $ErrorActionPreference = 'Continue'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $Branch     = 'claude/custom-ai-hosting-platform-z6h61i'
    $ZipUrl     = "https://github.com/lolrida/JARVIS/archive/refs/heads/$Branch.zip"
    $IpaUrl     = 'https://github.com/lolrida/JARVIS/releases/download/ios-latest/JARVIS.ipa'
    $StarterModel = 'llama3.2:3b'
    $Dir        = Join-Path $env:USERPROFILE 'JARVIS'
    $StateDir   = Join-Path $env:LOCALAPPDATA 'JARVIS'
    $Desktop    = [Environment]::GetFolderPath('Desktop')
    $Server     = 'http://localhost:8000'

    function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
    function Ok($text)   { Write-Host "    OK  $text" -ForegroundColor Green }
    function Info($text) { Write-Host "    $text" }
    function Warn($text) { Write-Host "    !!  $text" -ForegroundColor Yellow }
    function Fail($text) { Write-Host ""; Write-Host "ERRORE: $text" -ForegroundColor Red; Write-Host "Risolvi e rilancia lo stesso comando: riprende da dove si era fermato." }

    function Test-Docker {
        & docker info *> $null
        return ($LASTEXITCODE -eq 0)
    }

    function Invoke-Jarvis($Method, $Path, $Key, $Body) {
        $params = @{ Method = $Method; Uri = "$Server$Path"; Headers = @{ Authorization = "Bearer $Key" }; TimeoutSec = 600 }
        if ($null -ne $Body) {
            $params.ContentType = 'application/json'
            $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5))
        }
        return Invoke-RestMethod @params
    }

    Set-Location $env:USERPROFILE
    Write-Host ""
    Write-Host "  J A R V I S  -  installazione per Windows" -ForegroundColor Cyan
    Write-Host "  I tuoi modelli AI, sul tuo PC, 24/7." -ForegroundColor DarkGray

    # ------------------------------------------------------------------ 1. Docker
    Step "1/8  Docker Desktop"
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Info "Docker Desktop non c'e'. Lo installo (Windows potrebbe chiederti conferma, servono ~5 minuti)..."
            & winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { Fail "Installazione di Docker Desktop non riuscita. Scaricalo da https://www.docker.com/products/docker-desktop/"; return }
        } else {
            Start-Process 'https://www.docker.com/products/docker-desktop/'
            Fail "Installa Docker Desktop dalla pagina che si e' appena aperta."
            return
        }
        Write-Host ""
        Warn "Docker Desktop e' installato. Adesso:"
        Warn "  1) RIAVVIA il PC"
        Warn "  2) apri Docker Desktop e accetta le condizioni"
        Warn "  3) rilancia questo stesso comando"
        return
    }
    if (-not (Test-Docker)) {
        $exe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
        if (Test-Path $exe) { Start-Process $exe }
        Info "Avvio Docker Desktop (fino a 3 minuti)..."
        for ($i = 0; $i -lt 90 -and -not (Test-Docker); $i++) { Start-Sleep -Seconds 2 }
        if (-not (Test-Docker)) {
            Fail "Docker non risponde. Apri Docker Desktop, aspetta 'Engine running' (se chiede di accettare condizioni o aggiornare WSL, fallo), poi rilancia."
            return
        }
    }
    Ok "Docker funziona"

    # ------------------------------------------------------------------ 2. Code
    Step "2/8  Scarico JARVIS in $Dir"
    $tmp = Join-Path $env:TEMP ("jarvis-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'jarvis.zip'
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
        # Your models, keys and chats live in Docker volumes, not in this folder, so replacing it is safe.
        if (Test-Path $Dir) { Remove-Item -Recurse -Force $Dir }
        Move-Item -Path $src.FullName -Destination $Dir
    } catch {
        Fail "Download non riuscito: $($_.Exception.Message)"
        return
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    Ok "Codice aggiornato"

    # ------------------------------------------------------------------ 3. Start
    Step "3/8  Avvio JARVIS (la prima volta scarica ~1-2 GB: puo' volerci qualche minuto)"
    Push-Location $Dir
    try {
        & docker compose up -d --build
        if ($LASTEXITCODE -ne 0) { Fail "docker compose non e' riuscito ad avviare JARVIS (vedi i messaggi sopra)."; return }

        $healthy = $false
        for ($i = 0; $i -lt 90; $i++) {
            try {
                $h = Invoke-RestMethod -Uri "$Server/health" -TimeoutSec 3
                if ($h.status -eq 'ok' -and $h.engine) { $healthy = $true; break }
            } catch { }
            Start-Sleep -Seconds 2
        }
        if (-not $healthy) { Fail "JARVIS non risponde su $Server. Controlla con: cd $Dir; docker compose logs"; return }
        Ok "JARVIS e' acceso su $Server (riparte da solo con Docker Desktop)"

        # -------------------------------------------------------------- 4. Keys
        Step "4/8  Chiavi di accesso"
        $adminKey = ((& docker compose exec -T jarvis cat /data/admin_key.txt) -join '').Trim()
        if (-not $adminKey.StartsWith('jv-')) { Fail "Non trovo la chiave admin."; return }
        Ok "Chiave admin trovata"

        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
        $phoneFile = Join-Path $StateDir 'iphone-key.txt'
        $phoneKey = $null
        if (Test-Path $phoneFile) {
            $saved = (Get-Content $phoneFile -Raw).Trim()
            try { Invoke-Jarvis GET '/api/whoami' $saved $null | Out-Null; $phoneKey = $saved } catch { }
        }
        if (-not $phoneKey) {
            $created = Invoke-Jarvis POST '/api/keys' $adminKey @{ name = 'iphone'; is_admin = $true }
            $phoneKey = $created.key
            Set-Content -Path $phoneFile -Value $phoneKey -Encoding ASCII
            Ok "Creata una chiave per l'iPhone"
        } else {
            Ok "Chiave iPhone gia' esistente, la riuso"
        }

        # -------------------------------------------------------------- 5. Network
        Step "5/8  Rete per l'iPhone"
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
        $lanIp = $null
        if ($route) {
            $lanIp = (Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
        }
        if (-not $lanIp) { $lanIp = 'IP-DEL-PC' }
        $phoneServer = "${lanIp}:8000"
        Ok "Indirizzo per l'iPhone (stessa Wi-Fi): $phoneServer"

        if (-not (Get-NetFirewallRule -DisplayName 'JARVIS (porta 8000)' -ErrorAction SilentlyContinue)) {
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            try {
                if ($isAdmin) {
                    New-NetFirewallRule -DisplayName 'JARVIS (porta 8000)' -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Private | Out-Null
                } else {
                    Info "Windows ti chiedera' il permesso per aprire la porta 8000 sul firewall: rispondi Si'."
                    $rule = "New-NetFirewallRule -DisplayName 'JARVIS (porta 8000)' -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Private | Out-Null"
                    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($rule))
                    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -EncodedCommand $encoded"
                }
            } catch { }
        }
        if (Get-NetFirewallRule -DisplayName 'JARVIS (porta 8000)' -ErrorAction SilentlyContinue) {
            Ok "Firewall: porta 8000 aperta sulle reti private"
        } else {
            Warn "Firewall non configurato: se l'iPhone non si collega, rilancia lo script e accetta la richiesta di Windows."
        }
        if ($route) {
            $netProfile = Get-NetConnectionProfile -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue
            if ($netProfile -and $netProfile.NetworkCategory -eq 'Public') {
                Warn "La tua rete e' impostata come PUBBLICA: l'iPhone non potra' collegarsi."
                Warn "Impostazioni > Rete e Internet > Wi-Fi (o Ethernet) > la tua rete > Tipo di profilo: Privata."
            }
        }

        # -------------------------------------------------------------- 6. Starter model
        Step "6/8  Il tuo primo modello"
        $models = Invoke-Jarvis GET '/api/models' $adminKey $null
        if ($models.custom | Where-Object { $_.name -eq 'jarvis' }) {
            Ok "Il modello 'jarvis' esiste gia'"
        } else {
            $hasBase = $models.base | Where-Object { $_.name -eq $StarterModel }
            if (-not $hasBase) {
                Info "Scarico $StarterModel (~2 GB, funziona anche senza scheda video)..."
                & docker compose exec ollama ollama pull $StarterModel
                if ($LASTEXITCODE -ne 0) { Fail "Download del modello non riuscito. Rilancia lo script per riprovare."; return }
            }
            $system = "Sei JARVIS, l'assistente personale del tuo proprietario. Rispondi nella lingua in cui ti scrivono, in modo chiaro, utile e conciso."
            Invoke-Jarvis POST '/api/models' $adminKey @{
                name = 'jarvis'; base = $StarterModel; description = 'Il mio assistente personale'
                system = $system; parameters = @{ temperature = 0.7 }
            } | Out-Null
            Ok "Creato il modello 'jarvis' (versione 1)"
        }
    } finally {
        Pop-Location
    }

    # ------------------------------------------------------------------ 7. iPhone app
    Step "7/8  App iPhone"
    $ipa = Join-Path $Desktop 'JARVIS.ipa'
    try {
        Invoke-WebRequest -Uri $IpaUrl -OutFile $ipa -UseBasicParsing
        Ok "Scaricata sul Desktop: JARVIS.ipa"
    } catch {
        $ipa = $null
        Warn "App iPhone non ancora disponibile da scaricare. Riprova piu' tardi rilanciando lo script."
    }

    # ------------------------------------------------------------------ 8. Credentials
    Step "8/8  Credenziali"
    $credFile = Join-Path $Desktop 'JARVIS - credenziali.txt'
    $text = @"
JARVIS - le tue credenziali  (creato il $(Get-Date -Format 'dd/MM/yyyy HH:mm'))
====================================================================
TIENILE SEGRETE: chi ha una chiave admin controlla i tuoi modelli.
Consiglio: copiale in un password manager e poi cancella questo file.

PANNELLO DI CONTROLLO (su questo PC)
  Indirizzo:     $Server
  Chiave admin:  $adminKey

APP IPHONE
  Server:        $phoneServer        (iPhone sulla stessa Wi-Fi del PC)
  Chiave:        $phoneKey

APP WEB PER IPHONE (alternativa senza installare nulla)
  In Safari apri http://$phoneServer/app , accedi con la chiave iPhone,
  poi Condividi > Aggiungi alla schermata Home.

INSTALLARE L'APP IPHONE (JARVIS.ipa sul Desktop)
  1. Scarica Sideloadly: https://sideloadly.io
  2. Collega l'iPhone con il cavo, trascina JARVIS.ipa in Sideloadly,
     inserisci il tuo Apple ID e premi Start.
  3. Sull'iPhone: Impostazioni > Privacy e sicurezza > Modalita' sviluppatore: ON
     poi Impostazioni > Generali > VPN e gestione dispositivi > autorizza il tuo Apple ID.
  4. Apri JARVIS e inserisci Server e Chiave qui sopra.
  Con un Apple ID gratuito l'app va reinstallata ogni 7 giorni (le chat restano).

COMANDI UTILI (PowerShell)
  Riavviare:       cd $Dir; docker compose restart
  Fermare:         cd $Dir; docker compose stop
  Aggiornare:      rilancia il comando di installazione
  Nuova chiave:    cd $Dir; docker compose exec jarvis jarvis create-key --name NOME
  Chiave admin:    cd $Dir; docker compose exec jarvis cat /data/admin_key.txt
"@
    Set-Content -Path $credFile -Value $text -Encoding UTF8
    Ok "Salvate in: $credFile"

    Write-Host ""
    Write-Host "  FATTO. JARVIS e' acceso." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Pannello:      $Server"
    Write-Host "  Chiave admin:  $adminKey"
    Write-Host "  iPhone:        server $phoneServer  /  chiave $phoneKey"
    Write-Host ""
    Write-Host "  Ti apro il pannello e il file delle credenziali." -ForegroundColor DarkGray
    Start-Process $Server
    Start-Process notepad.exe -ArgumentList "`"$credFile`""
}

Install-Jarvis
