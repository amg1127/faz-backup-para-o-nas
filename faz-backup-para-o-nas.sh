#!/bin/bash

# Script para fazer backup dos dados que estao no computador novo para o computador velho. Para isso, usa "rsync" sobre "SSH"...
# CUIDADO: nao usar nomes de pasta com espaco!!!
export hostremoto='amg1127-london'
export caminholocal='/home/amg1127/backups'
export caminhoremoto='/home/amg1127/backups'
export maxbackups=15

###########################################

export anomesdia="`date '+%Y-%m-%d'`"
export arqbloqueio=".lockfile"
export maska='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
set -o pipefail
test "x${FAST}" != "x" || sleep 10
test "x${HOSTREMOTO}" != "x" && export hostremoto="${HOSTREMOTO}"

exibe () {
    echo " [`date '+%Y-%m-%d %H:%M:%S'`] $@ "
}

sai () {
    codsaida="$1"
    if ! [ "x${FAST}" != "x" -a "${codsaida}" -eq 0 ]; then
        echo ' '
        echo ' **** Pressione ENTER para continuar... ****'
        read DUMMY
    fi
    rm -f "${caminholocal}/${arqbloqueio}"
    exit $codsaida
}

morre () {
    exibe "$@"
    exibe ' **** O programa nao foi executado com sucesso! ****'
    sai 1
}

roda () {
    ssh -o ControlPath=none -n -- "${hostremoto}" "$@"
}

rodasuc () {
    roda "$@"
    if [ "$?" -ne 0 ]; then
        morre "Linha de comando '$@' falhou!"
    fi
}

definitivo2temporario () {
    sed -r "s/^(.*\/)?(${maska})(\/.*)?\$/\1.\2.tmp\3/"
}

temporario2definitivo () {
    sed -r "s/^(.*\/)?\.(${maska})\.tmp(\/.*)?\$/\1\2\3/"
}

busca_remoto () {
    rodasuc find "${caminhoremoto}" -mindepth 1 -maxdepth 1 -type d "$@"
}

busca_temporarios () {
    busca_remoto -iname ".${maska}.tmp"
}

busca_definitivos () {
    busca_remoto -iname "${maska}"
}

latestLink () {
    if roda test -e "${caminhoremoto}/latest"; then
        rodasuc test -h "${caminhoremoto}/latest"
    fi
    rodasuc rm -f "${caminhoremoto}/latest"
    latestTarget="`busca_definitivos | sort -r | head --lines=1`"
    [ "x${latestTarget}" != 'x' ] && rodasuc ln -sv "${latestTarget}" "${caminhoremoto}/latest"
}

if [ -f "${caminholocal}/${arqbloqueio}" ]; then
    echo 'Outra instancia deste programa parece estar em execucao. Abortando...'
    exit 1
fi

if [ "x${SSH_AGENT_PID}" == "x" ]; then
    exibe 'Agente de SSH nao foi localizado. Lancando um...'
    exec ssh-agent "${0}" "$@"
fi

exibe '(1) Testando autenticacao de SSH...'
exibe 'Aviso: O ideal eh que o SSH faca autenticacao sem a necessidade de digitar senha.'
exibe 'Se a digitacao de senha foi necessaria, interrompa este script e use o comando "ssh-add" antes de executar este script.'
if ! ssh-add -l; then
    ssh-add
fi
if ! roda mkdir -p -m 700 "${caminhoremoto}"; then
    morre 'Impossivel autenticar-se no servidor de SSH!'
fi

echo $$ > "${caminholocal}/${arqbloqueio}"

echo ' '
exibe '(2) Verificando pastas de backup existentes...'
camremot="`echo \"${caminhoremoto}/${anomesdia}\" | definitivo2temporario`"
if [ "`( busca_definitivos | definitivo2temporario ; busca_temporarios ; echo "${camremot}" ) | sort -r | head --lines=1`" != "${camremot}" ]; then
    morre '???? Existe um backup que veio do futuro? ????'
fi
if roda test -d "${caminhoremoto}/${anomesdia}"; then
    if [ "x${FAST}" != "x" ]; then
        exibe 'Aviso: Ja foi feito backup hoje! Ele sera sobrescrito...'
        rodasuc mv -v "${caminhoremoto}/${anomesdia}" "${camremot}"
        rodasuc touch "${camremot}"
        latestLink
    else
        morre 'Ja foi feito backup hoje!'
    fi
fi
if [ "`find -L "${caminholocal}" -mindepth 1 -maxdepth 1 -type d | egrep '[[:space:]]' | wc --lines`" -gt 0 ]; then
    morre 'Nomes de symlinks invalidos aqui na origem!'
fi

rodasuc mkdir -pv -m 700 "${camremot}"
if ! roda test -d "${camremot}"; then
    morre 'Falha ao criar pasta para o backup de hoje! Impossivel continuar!'
fi

rsynclinkdeststemplate="`( busca_definitivos | definitivo2temporario | sed -r 's/$/D/' ; busca_temporarios | sed -r 's/$/T/' | sort -r | head --lines=5 ) | sort -r | head --lines=20 | while read localo; do
    echo \"${localo}\" | egrep -q 'D$' && echo \"${localo}\" | sed -r 's/D$//' | temporario2definitivo
    echo \"${localo}\" | egrep -q 'T$' && echo \"${localo}\" | sed -r 's/T$//'
done`"

echo ' '
exibe '(3) Executando chamadas de "rsync" para fazer o backup...'
find -L "${caminholocal}" -mindepth 1 -maxdepth 1 -type d | while read localo; do
    if ! (
        resultado='0'
        runscript="${localo}-prereq"
        if [ -f "${runscript}" -a -x "${runscript}" ]; then
            exibe "  + prereq '${localo}'"
            . "${runscript}" "${resultado}"
            if [ "${?}" -ne 0 ]; then
                morre "Falha ao executar script de pre-requisito para sincronizacao do caminho '${localo}'."
            fi
        fi
        runscript="${localo}-prerun"
        if [ -f "${runscript}" -a -x "${runscript}" ]; then
            exibe "  + prerun '${localo}'"
            . "${runscript}" "${resultado}"
            resultado="${?}"
        fi
        if [ "${resultado}" -eq 0 ]; then
            bnlo="`basename \"${localo}\"`"
            exibe "  + rsync '${localo}'"
            logofile="${localo}-transfer.log"
            cat /dev/null > "${logofile}"
            rsyncmore=''
            for inctest in 'in' 'ex'; do
                patfile="${localo}-${inctest}clude.patterns"
                if [ -f "${patfile}" ]; then
                    rsyncmore="${rsyncmore} --${inctest}clude-from=${patfile}"
                fi
            done
            checkfile="${localo}-lastchecksumtimestamp"
            rstamp='-c'
            if [ -f "${checkfile}" ]; then
                if ! [ $((`date +%s`-2592000)) -ge "`stat -c '%Y' \"${checkfile}\"`" ]; then
                    rstamp=''
                fi
            fi
            if [ "x${bnlo}" != "x" ]; then
                rsyncmore="${rsyncmore} `echo \"${rsynclinkdeststemplate}\" | while read comparedir; do
                    echo -n \" --link-dest=\\\"${comparedir}/${bnlo}/\\\"\"
                done`"
                rsync -e 'ssh -o ControlPath=none' ${rstamp} -z --new-compress -r -l -H -p -E -g -t --delete --delete-excluded --delete-before --timeout=43200 --safe-links --no-whole-file --no-inplace --log-file-format='%o %b/%l %n%L' --log-file="${logofile}" ${rsyncmore} "${localo}/" "${hostremoto}:${camremot}/${bnlo}/"
                resultado="$?"
                if [ "${resultado}" -eq 24 ]; then
                    exibe "Aviso: Ignorando falhas de transferencia por 'vanished files'..."
                    resultado=0
                fi
            else
                resultado=1
            fi
            runscript="${localo}-postrun"
            if [ -f "${runscript}" -a -x "${runscript}" ]; then
                exibe "  + postrun '${localo}'"
                . "${runscript}" "${resultado}"
                if [ "${?}" -ne 0 ]; then
                    exibe "Aviso: Falha ao executar script de pos-execucao para sincronizacao do caminho '${localo}'."
                fi
            fi
            if [ "${resultado}" -eq 0 ]; then
                if [ "x${rstamp}" == "x-c" ]; then
                    touch "${checkfile}"
                fi
            else
                morre "Falha ao sincronizar caminho '${localo}'."
            fi
        else
            exibe "Aviso: Falha ao executar script de pre-execucao para sincronizacao do caminho '${localo}'. Pulando backup..."
        fi
    ) < /dev/null; then
        exit 1
    fi
done
[ "$?" -eq 0 ] || morre 'Abortando...'
rodasuc mv -v "${camremot}" "${caminhoremoto}/${anomesdia}"
latestLink

echo ' '
exibe '(4) Removendo pastas de backup antigas...'
busca_definitivos | sort -r | cat -n | while read posi pname; do
    if [ "${posi}" -gt "${maxbackups}" ]; then
        exibe "  + Removendo '${pname}'..."
        roda rm -Rf "${pname}"
    fi
done

echo ' '
exibe '(5) Removendo pastas de backup temporarias...'
busca_temporarios | while read linha; do
    exibe "  + Removendo '${linha}'..."
    roda rm -Rf "${linha}"
done

echo ' '
exibe '(6) Executando verificacao de encerramento...'
roda find "${caminhoremoto}/${anomesdia}" -mindepth 1 -maxdepth 1 -type d | while read umdir; do
    base="`basename \"${umdir}\"`"
    if ! test -d "${caminholocal}/${base}"; then
        exibe "Aviso: nao existe referencia de diretorio de origem para o backup de nome '${base}'!"
    fi
done

echo ' '
exibe ' OK! '
sai 0
