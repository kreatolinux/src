import ../modules/logger
import ../modules/downloader

proc getNews() =
    ## Download latest news
    download("https://mirror.kreato.dev/newsList.ini", "/var/cache/kpkg/newsList.ini")
    info "Latest news downloaded."

proc news(update = false) =
    ## Get the news from the news file
    if update:
	getNews()
