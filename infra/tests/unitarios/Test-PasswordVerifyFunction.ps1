# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    Teste UNITARIO: valida a funcao KAWASHI_PASSWORD_VERIFY (infra/oracle-init/02_global_hardening.sql)
    isoladamente, sem criar nenhum usuario e sem depender de login algum.

.DESCRIPTION
    E "unitario" porque exercita uma unica unidade de codigo (a funcao PL/SQL)
    diretamente, chamando-a varias vezes dentro de um unico bloco anonimo, com
    entradas controladas - nao passa pelo fluxo real de CREATE USER/ALTER USER,
    que e onde a funcao normalmente seria acionada pelo Oracle.

.EXAMPLE
    ./Test-PasswordVerifyFunction.ps1
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
)

. (Join-Path $PSScriptRoot '..\lib\TestHelpers.ps1')

Write-Host "== [UNITARIO] KAWASHI_PASSWORD_VERIFY ==" -ForegroundColor Cyan

# CORRIGIDO (achado rodando este teste pela primeira vez): a funcao e
# OWNED BY SYS - exigencia do proprio Oracle para qualquer PASSWORD_VERIFY_FUNCTION
# referenciada por um PROFILE (12.2+). Por causa da restricao O7_DICTIONARY_ACCESSIBILITY
# (ativa por padrao), o privilegio "EXECUTE ANY PROCEDURE" do role DBA do
# ENGINEER_USER NAO alcanca objetos de SYS - chamar "SYS.KAWASHI_PASSWORD_VERIFY"
# por esse usuario da PLS-00201 (nao e falta da funcao existir, e falta de
# privilegio, que o Oracle disfarca como "identifier must be declared"). Como
# este e um teste UNITARIO da propria funcao (nao do fluxo de criacao de
# usuario), conectamos "/ as sysdba" dentro do container, que e autenticacao
# por SO e sempre pode chamar qualquer objeto de SYS.
$sql = @'
ALTER SESSION SET CONTAINER = FREEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET VERIFY OFF
DECLARE
    PROCEDURE testar(p_rotulo VARCHAR2, p_user VARCHAR2, p_pwd VARCHAR2) IS
        v_ok BOOLEAN;
    BEGIN
        v_ok := KAWASHI_PASSWORD_VERIFY(p_user, p_pwd, NULL);
        IF v_ok THEN
            DBMS_OUTPUT.PUT_LINE(p_rotulo || '=ACEITA');
        ELSE
            DBMS_OUTPUT.PUT_LINE(p_rotulo || '=REJEITADA_SEM_ERRO');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE(p_rotulo || '=REJEITADA:' || SQLCODE);
    END;
BEGIN
    testar('CURTA',          'JOAO', 'Ab1!xy');
    testar('CONTEM_USUARIO', 'JOAO', 'JoaoSenhaForte1!');
    testar('SEM_ESPECIAL',   'JOAO', 'SenhaForte12345');
    testar('SEM_MAIUSCULA',  'JOAO', 'senhaforte123!');
    testar('SEM_NUMERO',     'JOAO', 'SenhaForteAbc!');
    testar('VALIDA',         'JOAO', 'C0rrect!HorseBattery');
END;
/
EXIT;
'@

$output = (Invoke-SqlPlus -ConnectString '/ as sysdba' -Sql $sql) -join "`n"

$casos = @(
    @{ Rotulo = 'CURTA';          Esperado = 'REJEITADA:-20001'; Descricao = 'Senha com menos de 12 caracteres deve ser rejeitada (ORA-20001)' }
    @{ Rotulo = 'CONTEM_USUARIO'; Esperado = 'REJEITADA:-20002'; Descricao = 'Senha contendo o nome do usuario deve ser rejeitada (ORA-20002)' }
    @{ Rotulo = 'SEM_ESPECIAL';   Esperado = 'REJEITADA:-20003'; Descricao = 'Senha sem caractere especial deve ser rejeitada (ORA-20003)' }
    @{ Rotulo = 'SEM_MAIUSCULA';  Esperado = 'REJEITADA:-20003'; Descricao = 'Senha sem letra maiuscula deve ser rejeitada (ORA-20003)' }
    @{ Rotulo = 'SEM_NUMERO';     Esperado = 'REJEITADA:-20003'; Descricao = 'Senha sem numero deve ser rejeitada (ORA-20003)' }
    @{ Rotulo = 'VALIDA';         Esperado = 'ACEITA';           Descricao = 'Senha forte valida deve ser aceita' }
)

$results = foreach ($caso in $casos) {
    $linhaEsperada = "$($caso.Rotulo)=$($caso.Esperado)"
    $passou = $output -match [regex]::Escape($linhaEsperada)
    New-TestResult -Name $caso.Descricao -Passed $passou -Details $(if (-not $passou) { "saida completa:`n$output" })
}

$results | ForEach-Object { Write-TestResult -Result $_ }
return $results
