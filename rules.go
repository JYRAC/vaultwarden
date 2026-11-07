package main

// IP制限の例外にする「公開の読み取り」のルール。
// 環境変数 GATE_PUBLIC_RULES に、ルール名をカンマ区切りで書いたものだけが有効になる。
//
// 共通の条件（どのルールも）:
//   - GET / HEAD だけ
//   - Authorization ヘッダーも Cookie も無い（匿名の読み取りだけ。トークンを持つ呼び出しは、例外にしない）
//   - パスに、完全一致をすり抜ける表記（..、//、;、%エンコード）が無い
//   - クエリは、許可したキーだけ。同じキーの重複や、未知のキーがあれば、不一致
//
// これらのルールは、拒否リストのIPと、CFヘッダーが不正なリクエストには、適用されない（gate.go）。
//
// ※ Go のコンパイラなしで書きました。`go vet ./...` と `go test ./...` で確認してください。

import (
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

type publicRule func(r *http.Request) bool

const uuidPattern = `[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}`

var (
	reNewsList   = regexp.MustCompile(`^/items/nsf_news$`)
	reNewsDetail = regexp.MustCompile(`^/items/nsf_news/([0-9]{1,12}|` + uuidPattern + `)$`)
	reAssets     = regexp.MustCompile(`^/assets/` + uuidPattern + `$`)
	reSort       = regexp.MustCompile(`^-?[a-z_]{1,32}$`)
	reLimit      = regexp.MustCompile(`^[0-9]{1,3}$`)
	reKey        = regexp.MustCompile(`^[A-Za-z0-9_-]{1,40}$`)
)

var publicRules = map[string]publicRule{
	"directus_news":   ruleDirectusNews,
	"directus_assets": ruleDirectusAssets,
}

// parseRules は、"directus_news,directus_assets" を読む。未知の名前があれば、起動時に失敗させる。
func parseRules(s string) ([]publicRule, error) {
	var out []publicRule
	for _, name := range strings.Split(s, ",") {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		rule, ok := publicRules[name]
		if !ok {
			return nil, fmt.Errorf("未知のルール名 %q", name)
		}
		out = append(out, rule)
	}
	return out, nil
}

// baseOK は、どのルールにも共通の条件。クエリも返す。
func baseOK(r *http.Request) (url.Values, bool) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return nil, false
	}
	if r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" {
		return nil, false
	}
	if !cleanExact(r) {
		return nil, false
	}
	q, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return nil, false
	}
	for _, vs := range q {
		if len(vs) != 1 {
			return nil, false
		}
	}
	return q, true
}

// ruleDirectusNews: お知らせの一覧と詳細（Astro の src/lib/directus.ts が呼ぶもの）。
//
//	一覧: GET /items/nsf_news?filter[status][_eq]=published&sort=-published_at&limit=N
//	詳細: GET /items/nsf_news/<数字 または UUID>（クエリなし）
func ruleDirectusNews(r *http.Request) bool {
	q, ok := baseOK(r)
	if !ok {
		return false
	}
	if reNewsDetail.MatchString(r.URL.Path) {
		return len(q) == 0
	}
	if !reNewsList.MatchString(r.URL.Path) {
		return false
	}
	if q.Get("filter[status][_eq]") != "published" {
		return false
	}
	for k := range q {
		v := q.Get(k)
		switch k {
		case "filter[status][_eq]":
			// 上で確認済み
		case "sort":
			if !reSort.MatchString(v) {
				return false
			}
		case "limit":
			if !reLimit.MatchString(v) {
				return false
			}
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 || n > 100 {
				return false
			}
		default:
			return false
		}
	}
	return true
}

// ruleDirectusAssets: 画像など（将来用）。GET /assets/<UUID>?key=<プリセット名> だけ。
// key（Directus のストレージプリセット）が必須: 元ファイルや、任意サイズの変換は、通さない。
func ruleDirectusAssets(r *http.Request) bool {
	q, ok := baseOK(r)
	if !ok {
		return false
	}
	if !reAssets.MatchString(r.URL.Path) {
		return false
	}
	if len(q) != 1 {
		return false
	}
	return reKey.MatchString(q.Get("key"))
}
