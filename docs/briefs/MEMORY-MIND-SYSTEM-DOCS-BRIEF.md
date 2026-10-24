# Brief: Memory, Mind, System Docs, Present, Clipboard, and the Browser's page

The request, word for word as it was given (2026-10-24). The work it set off is listed at the
end, as it ships.

---

lets add a new board, just like library we just added recently. call this one 'MEMORY'. also add another one like that called 'SYSTEM-DOCS' . finally add a new kind called 'MIND' WHICH USES 'Text mind-map notation.md' we have in the docs folder

SYSTEM DOCS is just like library except we cant edit it, it contains docs of e.g the mind map, straw,  all our api docs . it also contains prompts that a model could follow to effectively use the system.  it should contain example exchange, recipes etc. system docs also will have api that client can acces just like the others we have

we also need script/api etc that presents a file from any library to the user./ lets the file have copy buttons.  by presenting i mean we open a ui like modal pop up and bring to the front of the screen for user to see. so a client can call and we will do the pop up as the result.  add api that lets client copy any result to clipboard, so while they could fetch it, there should be option to have it copied to clip board.  

the memory is just like an opinionated library. it has files out of the box specifically named like 'PEOPLE', 'ORGANIZATIONS','EVENT-DATES','BIRTHDAYS','LOCATIONS','IDEAS','LEVRAGE','STRATEGIES' , and 'OTHERS'. each one of those are nodes in 'MIND'. so it's like the mind kind of indexes the memory. in mind, we should see a visualization and able to switch to text based view. api covers . more nodes can be added to the mind map . adding a connection to the mind map is append only. the text to mindmap notation has all the mechanism in place. a client can simply provide what to add , and we just append. also we shoudl have a group of scripts/api for querying the mind map. client can send in a query , and we can return result. have api to cover some most likely query to happen etc so a client  doers not even need to know the notation.  also we should have api for memory. since every  file in memory is a node in mind, api can allow managing of the files in memory just like we do with library. 

we want api/script/utility etc that a client can use to obtain what url is currentl;y visible in the browser, if the browser (chrome) is opened . it lets cleint see what is on the screen, not image , but detains of the page. the name , the url, the text content of the page . also in case we just want to return true/false about if a text is present on the page etc . the intent here is to have client guide the user in working on a site , e.g say user is on cloudflair and they dont know  where the 'compute' is , a client can use the api to  guide the user etc 

you get the overall intent, if i have any gaps, help me close them . if you find any bugs , help fix them. first emit this message here to some file in repo.. ship early and often as you cross milestons. help think through it well for good implementation that leaves nothing out. no library exists yet so we can put the folders inside a main folder called 'TOOL-MAC-RUN' or any better name to keep the folders organized
ship to main at each point. dont wait for builds in other branches

---

## Shipped

- [ ] This brief
