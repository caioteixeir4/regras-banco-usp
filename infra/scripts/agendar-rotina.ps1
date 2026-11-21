<#
.SYNOPSIS
    Agenda a rotina-diaria.ps1 no Agendador de Tarefas do Windows (ou tira o agendamento).

.DESCRIPTION
    Cria uma tarefa do usuario atual que roda a rotina todo dia no horario escolhido. Detalhes:
      - roda so com o usuario logado (nenhuma senha fica guardada no Windows), e por isso consegue
        mostrar o aviso na area de notificacao;
      - se o computador estiver desligado no horario, roda assim que ele voltar;
      - a janela do PowerShell nao aparece; o resultado fica em infra/logs/.

    Para tirar: ./agendar-rotina.ps1 -Remover
    Para ver: Agendador de Tarefas do Windows, pasta "Kawashi".

.PARAMETER Horario
    Horario diario, no formato HH:mm. Padrao: 09:00.

.PARAMETER Remover
    Tira o agendamento.

.PARAMETER NomeDaTarefa
    Nome da tarefa no Agendador. Padrao: "Rotina diaria de seguranca".

.EXAMPLE
    ./agendar-rotina.ps1

.EXAMPLE
    ./agendar-rotina.ps1 -Horario 08:30

.EXAMPLE
    ./agendar-rotina.ps1 -Remover
#>
[CmdletBinding()]
param(
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$Horario = '09:00',

    [switch]$Remover,

    [ValidatePattern('^[\w .\-]{1,80}$')]
    [string]$NomeDaTarefa = 'Rotina diaria de seguranca'
)

$ErrorActionPreference = 'Stop'
$pasta = '\Kawashi\'

if ($Remover) {
    if (Get-ScheduledTask -TaskPath $pasta -TaskName $NomeDaTarefa -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskPath $pasta -TaskName $NomeDaTarefa -Confirm:$false
        Write-Host "Agendamento '$NomeDaTarefa' removido." -ForegroundColor Green
    } else {
        Write-Host "Nao havia agendamento '$NomeDaTarefa'."
    }
    return
}

$rotina = (Resolve-Path (Join-Path $PSScriptRoot 'rotina-diaria.ps1')).Path
$acao = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$rotina`"" `
    -WorkingDirectory $PSScriptRoot
$gatilho = New-ScheduledTaskTrigger -Daily -At $Horario
# StartWhenAvailable: se o computador estava desligado no horario, roda quando voltar.
$config = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
# Interactive: so roda com o usuario logado, sem guardar senha no Windows.
$quem = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskPath $pasta -TaskName $NomeDaTarefa -Action $acao -Trigger $gatilho -Settings $config -Principal $quem `
    -Description 'Kawashi: confere senhas e contas com pendencia e ancora o log de alteracoes no Vault (infra/scripts/rotina-diaria.ps1).' -Force | Out-Null

Write-Host "Rotina agendada: todo dia as $Horario (tarefa '$NomeDaTarefa', pasta Kawashi do Agendador de Tarefas)." -ForegroundColor Green
Write-Host "Relatorios em: $((Resolve-Path (Join-Path $PSScriptRoot '..')).Path)\logs"
Write-Host "Para tirar: ./agendar-rotina.ps1 -Remover"
