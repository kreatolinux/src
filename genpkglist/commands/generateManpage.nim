import strutils

proc generateManpage*(file: string, output: string) =
    ## Generates a manpage.
    var manpageName: string

    let fileLet = open(file)
    
    let line = fileLet.readLine()

    let splittedLine = line.split("% ")

    if splittedLine.len > 1:
        manpageName = splittedLine[1]
    else:
        fileLet.close()
        # Probably not a manpage, exit
        echo "'"&file&"' is not a manpage, exiting"
        quit(1) 

    fileLet.close()

    var addition = "---\n"
    addition = addition&"title: \""&manpageName&"\"\n"
    addition = addition&"draft: false\n"
    addition = addition&"---"
    
    # For some reason using readLine removes the first line from fileLet, which is why i am doing this instead.
    # Shouldn't matter much.
    writeFile(output, readFile(file).replace(line, addition))
