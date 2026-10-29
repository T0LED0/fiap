#!/usr/bin/env bash
# ==============================================================================
# ToggleMaster - Script de Hard-Reset da branch 'main' remota no GitLab
#
# Este script:
# 1. Garante uma cópia local de segurança na branch 'backup/local-complete-code'.
# 2. Cria um commit raiz isolado com árvore totalmente vazia (0 arquivos).
# 3. Faz o force-push desse commit vazio para a branch 'main' remota no GitLab.
# 4. Remove branches remotas secundárias (para garantir limpeza total no GitLab).
# 5. Mantém todos os arquivos locais 100% intactos e inalterados no disco.
# ==============================================================================

set -euo pipefail

echo "=========================================================="
echo " [ToggleMaster] Reset Remoto da branch main no GitLab"
echo "=========================================================="

# 1. Backup local
echo "==> 1/4 Garantindo branch local de backup com todo o código..."
git branch -f backup/local-complete-code main
echo "    ✓ Branch 'backup/local-complete-code' atualizada com sucesso."

# 2. Criar commit raiz vazio
echo "==> 2/4 Gerando commit com árvore vazia (0 arquivos, sem histórico)..."
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
EMPTY_COMMIT=$(echo "chore: initial repository setup" | git commit-tree "$EMPTY_TREE")
echo "    ✓ Commit vazio criado: $EMPTY_COMMIT"

# 3. Push para origin/main
echo "==> 3/4 Enviando commit vazio para origin/main (force-push)..."
git push origin "$EMPTY_COMMIT":refs/heads/main --force
echo "    ✓ origin/main resetada com sucesso no GitLab!"

# 4. Limpar branch secundária remota se existir
echo "==> 4/4 Limpando branches secundárias remotas..."
if git ls-remote --heads origin refactor/clean-code-anti-ai-bloat | grep -q refactor; then
    git push origin --delete refactor/clean-code-anti-ai-bloat || true
    echo "    ✓ Branch secundária remota 'refactor/clean-code-anti-ai-bloat' removida."
else
    echo "    ✓ Nenhuma branch secundária remota encontrada."
fi

echo ""
echo "=========================================================="
echo " Concluído com sucesso!"
echo " - GitLab (remoto): 0 arquivos e histórico limpo na 'main'."
echo " - Local: 100% dos seus arquivos e histórico preservados."
echo "=========================================================="
