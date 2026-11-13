# Contrato do pacote

O que o app Postilla e o backend leem do que é gerado aqui (ARQ-07): só o dicionário. As histórias não vêm mais deste repositório: são criadas como rascunhos no backend (`postilla-backend`), que escreve cada `.tilla` (formato em `postilla-backend/docs/tilla.md`). Mudança incompatível neste arquivo sobe o major do pacote (ARQ-12).

```
zig build run -- fetch     baixa as fontes em data/
zig build run -- dict      out/dict.db
zig build run -- pack      out/dict-<versão>.db.gz e out/SHA256SUMS
zig build run -- publish   envia o pacote ao R2 e atualiza dict/latest
zig build test
```

## Pacote

| Arquivo | O que é |
|---|---|
| `dict-<versão>.db.gz` | Dicionário, gzip -9 |
| `SHA256SUMS` | sha256 do `.db` e do `.db.gz` |

A versão está em `meta.version` e no nome do arquivo.

## Publicação no R2

O pacote vai para o bucket público do R2, o mesmo das histórias, e substitui as Releases do GitHub e o `manifest.json` no Pages (ARQ-06, ARQ-20) como meio de entrega: o app e o backend só leem o R2. As Releases podem continuar como arquivo, mas nada as lê.

1. Envia `dict/<sha256>.db.gz`, onde `sha256` é o do `.db.gz`. Uma chave nunca é sobrescrita.
2. Só depois, sobrescreve `dict/latest`, um texto ASCII de uma linha: o sha256 em hexadecimal minúsculo, um espaço, o tamanho do `.db.gz` em bytes e `\n`.

```
3f2a…c9e1 22829235
```

Enviar o arquivo antes do ponteiro garante que quem lê um `dict/latest` novo sempre encontra o arquivo. Como o app usa o ponteiro está em `postilla-backend/docs/app-handoff.md`; o worker do backend o lê ao publicar uma história.

O build precisa de credenciais de escrita do bucket. Tokens do R2 valem para o bucket inteiro, não por prefixo: o build só escreve sob `dict/` e nunca toca em `stories/`, que é do backend.

## `dict`

```sql
CREATE TABLE meta  (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE entry (id INTEGER PRIMARY KEY, word TEXT NOT NULL, word_norm TEXT NOT NULL,
                    pos TEXT NOT NULL, band INTEGER NOT NULL, data TEXT NOT NULL);
CREATE TABLE form  (form TEXT NOT NULL, form_norm TEXT NOT NULL, entry_id INTEGER NOT NULL);
-- índices: entry(word), entry(word_norm), form(form), form(form_norm)
```

- `entry`: uma linha por lema e classe. `word` com a grafia original; `word_norm` minúscula e sem acento (ARQ-63).
- `pos`: a classe em italiano (`sostantivo`, `verbo`, `aggettivo`, `avverbio`, `nome proprio`, `locuzione`…).
- `band`: faixa do NVdB (ARQ-64): 0 fora · 1 fondamentale · 2 alto uso · 3 alta disponibilità. Não há rank dentro da faixa: o NVdB só publica as faixas.
- `form`: forma → lema, inclusive as das tabelas de conjugação com clítico ("si siede" → *sedersi*), o particípio e o gerúndio. Uma forma pode levar a mais de um lema ("porta" → *portare*, *porgere*).
- `entry.id` muda a cada build: ninguém o guarda (ARQ-35). Um `.tilla` guarda só spans de palavra; o app procura o texto do span por forma (`form`, depois `form_norm`).
- `meta`: `version`, `wiktionary_dump` (data do dump, AAAA-MM-DD), `license`, `attribution` e uma linha `source.<arquivo>` por fonte, com URL e sha256.

O worker do backend também lê `dict.db`, para `band_words` de cada `.tilla`: cada palavra conta na faixa mais comum entre os lemas a que sua forma leva (1 antes de 2, antes de 3, antes de 0); forma sem lema conta como 0.

`entry.data` é JSON. Campo sem dado não aparece.

| Campo | Tipo | Seção do verbete |
|---|---|---|
| `word`, `pos` | texto | Lemma e Classe |
| `tags` | lista: `maschile`, `femminile`, `invariabile` | Classe |
| `valency` | `transitivo` · `intransitivo` · `intransitivo pronominale` · `riflessivo` | Classe (verbo) |
| `aux` | `avere` · `essere` | Classe (verbo) |
| `flex` | lista de `{form, tags}`; `tags` como "plurale", "femminile singolare" | Flessione |
| `syll` | lista de sílabas, com o acento tônico | Sillabazione |
| `ipa` | texto | Pronuncia |
| `gloss` | até 3 traduções em português | Glosa PT |
| `gloss_src` | `wikt` · `wikdict` · `pivo-en` · `correzione` | (crédito) |
| `senses` | lista de `{gloss, labels?, examples?}`; `labels` são abreviações (`fig.`, `med.`) | Significati |
| `conj` | lista de `{tense, person, forms}`; `tense` 1 presente · 2 passato prossimo · 3 imperfetto · 4 futuro · 5 imperativo; `person` 1 io … 6 loro; no imperativo, `forms` de `person` 2 inclui o negativo ("non parlare") | Coniugazione |
| `participle`, `gerund` | texto | Coniugazione |
| `etym` | texto | Etimologia |
| `syn`, `ant`, `derived` | lista de `{word, note?}` | Sinonimi, Contrari, Parole derivate |
| `related`, `confusables` | lista de palavras | Termini correlati, Da non confondere con |
| `altered` | lista de `{word, kind}`; `kind` `diminutivo` · `accrescitivo` · `vezzeggiativo` · `peggiorativo` | Alterati |

## Palavra

A regra que o backend usa para os spans de palavra de cada `.tilla`, em todas as línguas, e que as formas de `form` devem seguir para que a busca do app as encontre: letras e dígitos; o apóstrofo e o hífen entre letras unem (*l'aria*, *c'è*, *porta-finestra*); o apóstrofo final fica nos truncamentos (*po'*, *va'*). Pontuação nunca é palavra.

## Arquivos-fonte escritos à mão

| Arquivo | O que é |
|---|---|
| `nvdb.tsv` | NVdB (De Mauro, 2016): lema, homógrafo, classes, faixa. Extraído uma vez do PDF da Internazionale por `tools/nvdb_extract.py` (faixa pela fonte: negrito, normal, itálico) |
| `corrections.tsv` | lema, classe, campo, valor. Campo `gloss`: traduções separadas por ` \| ` |
