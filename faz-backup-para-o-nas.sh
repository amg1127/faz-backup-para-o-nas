#!/bin/bash

# Script para fazer backup dos dados que estao no computador novo para o computador velho. Para isso, usa "rsync" sobre "SSH"...
# CUIDADO: nao usar nomes de pasta com espaco!!!
export hostremoto='amg1127-nas'
export caminhoremoto='/home/amg1127/backups'
export maxbackups=7

###########################################

export anomesdia="`date '+%Y-%m-%d'`"
export arqbloqueio=".lockfile"
export maska='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
set -o pipefail

exibe () {
    echo " [`date '+%Y-%m-%d %H:%M:%S'`] $@ "
}

sai () {
    codsaida="$1"
    echo ' '
    echo ' **** Pressione ENTER para continuar... ****'
    read DUMMY
    rm -f "${caminhoremoto}/${arqbloqueio}"
    exit $codsaida
}

morre () {
    exibe "$@"
    exibe ' **** O programa nao foi executado com sucesso! ****'
    sai 1
}

roda () {
    ssh -n -- "${hostremoto}" "$@"
}

rodasuc () {
    roda "$@"
    if [ "$?" -ne 0 ]; then
        morre "Linha de comando '$@' falhou!"
    fi
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

if [ "x${SSH_AGENT_PID}" == "x" ]; then
    exibe 'Agente de SSH nao foi localizado. Lancando um...'
    exec ssh-agent $0 "$@"
fi

if [ -f "${caminhoremoto}/${arqbloqueio}" ]; then
    echo 'Outra instancia deste programa parece estar em execucao. Abortando...'
    exit 1
fi

exibe '(1) Testando autenticacao de SSH...'
exibe 'Aviso: O ideal eh que o SSH faca autenticacao sem a necessidade de digitar senha.'
exibe 'Se a digitacao de senha foi necessaria, interrompa este script e use o comando "ssh-add" antes de executar este script.'
if ! roda mkdir -p -m 700 "${caminhoremoto}"; then
    morre 'Impossivel autenticar-se no servidor de SSH!'
fi

touch "${caminhoremoto}/${arqbloqueio}"

echo ' '
exibe '(2) Verificando e removendo pastas de backup incompletas...'
if [ "`( echo \"${caminhoremoto}/.${anomesdia}.tmp\" ; ( busca_definitivos | sed \"s/\/\(${maska}\)\$/\/.\1.tmp/\" ) ; busca_temporarios ) | sort -r | head --lines=1`" != "${caminhoremoto}/.${anomesdia}.tmp" ]; then
    morre '???? Existe um backup que veio do futuro? ????'
fi
if roda test -d "${caminhoremoto}/${anomesdia}"; then
    morre 'Ja foi feito backup hoje!'
fi
if [ "`find -L "${caminhoremoto}" -mindepth 1 -maxdepth 1 -type d | egrep '[[:space:]]' | wc --lines`" -gt 0 ]; then
    morre 'Nomes de symlinks invalidos aqui na origem!'
fi

camremot="${caminhoremoto}/.${anomesdia}.tmp"
if ! roda test -d "${camremot}"; then
    ultimapa="`( ( busca_definitivos | sed \"s/\/\(${maska}\)\$/\/.\1.tmp/\" ) ; busca_temporarios ) | sort -r | head --lines=1`"
    if [ "x${ultimapa}" != "x" ]; then
        if roda test -d "${ultimapa}"; then
            exibe "  + Copiando backup '`basename \"${ultimapa}\"`' para '`basename \"${camremot}\"`'..."
            rodasuc cp -a -f -x -l "${ultimapa}" "${camremot}"
        else
            ultimapa="`echo \"${ultimapa}\" | sed \"s/\/\.\(${maska}\)\.tmp\$/\/\1/\"`"
            if roda test -d "${ultimapa}"; then
                exibe "  + Copiando backup '`basename \"${ultimapa}\"`' para '`basename \"${camremot}\"`'..."
                rodasuc cp -a -f -x -l "${ultimapa}" "${camremot}"
            else
                morre '???? Inconsistencia feia aqui... ????'
            fi
        fi
    else
        rodasuc mkdir -pv -m 700 "${camremot}"
    fi
fi
if ! roda test -d "${camremot}"; then
    morre 'Falha ao criar pasta para o backup de hoje! Impossivel continuar!'
fi

echo ' '
exibe '(3) Executando chamadas de "rsync" para fazer o backup...'
find -L "${caminhoremoto}" -mindepth 1 -maxdepth 1 -type d | while read localo; do
    bnlo="`basename \"${localo}\"`"
    exibe "  + rsync '${localo}'"
    logofile="${localo}-transfer.log"
    cat /dev/null > "${logofile}"
    if ! ( [ "x${bnlo}" != "x" ] && rsync -v -e ssh -r -l -H -p -E -g -t --delete-before --timeout=300 --safe-links --log-file-format='%o %b/%l %n%L' --log-file="${logofile}" "${localo}/" "${hostremoto}:${camremot}/${bnlo}/" ); then
        morre "Falha ao sincronizar caminho '${localo}'." < /dev/null
    fi
done
[ "$?" -eq 0 ] || morre 'Abortando...'
rodasuc mv -v "${camremot}" "${caminhoremoto}/${anomesdia}"

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
exibe ' OK! '
sai 0
