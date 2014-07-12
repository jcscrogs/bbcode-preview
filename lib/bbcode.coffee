# Module for dealing with BBcode.
# This module is extensible, allowing "new" BBCode to be added.
# Tags may optionally take an argument, and closing tags may optionally require
# the closing argument to match. (So [list=1][/list=1] versus [list=1][/list])

# Utility functions
isValidURL = (url) ->
  /^(?:https?|ftp):\/\//i.test(url)

escapeHTML = (str) ->
  str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

escapeHTMLAttr = (str) ->
  escapeHTML(str).replace(/"/g, '&quot;').replace(/'/g, '&#39;')

class TextEvent
  constructor: (state, text) ->
    @state = state
    @text = text

class TagEvent
  constructor: (state, token) ->
    @state = state
    @tag = token.name
    {@arg, @raw} = token

# A BBCode Tag.
#
# The Tag class is basically a BBNode factory - a class that can
# create BBNodes inside the parse tree.
#
# As such the tag class itself only handles receives events that create BBNodes.
# Once the BBNode is added and stuffed on the top of the stack, it receives
# further parse events until the parse is complete.
#
# The default Tag class can be given a BBNode class that will be instantiated
# whenever onStartTag is received. If the start tag has arguments, it will be
# assumed to be invalid and nothing will be added.
class Tag
  constructor: (nodeClass) ->
    @nodeClass = nodeClass

  # Indicates that a tag for this tag class is starting. This method should
  # create and return an appropriate BBNode that will handle the remaining
  # parse events. If this tag cannot handle this event (for example, the
  # arguments are invalid), it should return <code>null</code> in which case it
  # will be converted into a corresponding text event and delivered to the
  # current node.
  onStartTag: (event) ->
    if event.arg?
      null
    else
      new @nodeClass()

class SimpleTag extends Tag
  constructor: (htmlElement) ->
    super()
    @htmlStart = "<#{htmlElement}>"
    @htmlEnd = "</#{htmlElement}>"

  onStartTag: (event) ->
    if event.arg?
      null
    else
      new BBElement(@htmlStart, @htmlEnd)

class URLTag extends Tag
  constructor: ->
    super(null)

  onStartTag: (event) ->
    if isValidURL event.arg
      new BBElement("<a href=\"#{escapeHTMLAttr(event.arg)}\" rel=\"nofollow\">", "</a>")
    else
      null

class ImgTag extends Tag
  constructor: ->
    super(null)

  onStartTag: (event) ->
    if event.arg?
      null
    else
      # Because we won't know if it's valid until after it ends, store the raw
      # value
      new BBImgElement(event.raw)

convertNewlinesToHTML = (text) ->
  if (text.length == 0)
    return "<p></p>";
  # First, normalize newlines
  text = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n")
  # Remove the final newline if there is one
  if (text.charAt(text.length-1) == "\n")
    text = text.substring(0,text.length-1)
  # And convert
  text = text.replace(/\n/g, "<br>\n").replace(/<br>\n<br>\n/g, "</p>\n\n<p>")
  '<p>' + text + '</p>'

class TagTokenizer
  constructor: (str) ->
    @str = str
    @currentOffset = 0
    @nextToken = @_next()

  # Determines if the text is a valid tag (allowed between [ and ])
  isValidTag: (tag) ->
    /^\/?[A-Za-z]+(?:=[^\]]*|="[^"]*")?$/.test(tag)

  hasNext: ->
    @nextToken != null

  next: ->
    if (@nextToken == null)
      throw Error("No more tokens")
    result = @nextToken
    if (@nextToken.type == 'text')
      # Merge text tokens if there are any
      nextNext = @_next()
      while nextNext != null and nextNext.type == 'text'
        result.text += nextNext.text
        nextNext = @_next()
      @nextToken = nextNext
    else
      @nextToken = @_next()
    if (result.type == 'tag' and result.name.charAt(0) == '/')
      result.name = result.name.substring(1)
      result.type = 'endtag';
    result

  #
  # Internal implementation of next, before multiple text tokens are merged.
  #
  _next: ->
    #console.log("_next(%d)", this.currentOffset);
    if (@currentOffset >= @str.length)
      return null;
    # This is fairly simple: are we starting with a [?
    if (@str.charAt(@currentOffset) == '[')
      # Assume this is a tag for now
      idx = @str.indexOf(']', @currentOffset)
      if (idx < 0)
        # Last token! Because we can never find an end tag
        tok = { type: 'text', text: @str.substring(@currentOffset) }
        @currentOffset = @str.length
        return tok
      # Otherwise, grab the contents as a tag, maybe
      tag = @str.substring(@currentOffset+1, idx)
      # Is this a real tag?
      if (@isValidTag(tag))
        # OK - now we split it into a tag and an argument (if any)
        name = tag;
        arg = null;
        eqIdx = tag.indexOf('=');
        if (eqIdx >= 0)
          name = tag.substring(0, eqIdx);
          arg = tag.substring(eqIdx + 1);
          # If the argument is surrounded by quotes, remove them
          if (arg.charAt(0) == '"' and arg.charAt(arg.length-1) == '"')
            arg.substring(1, arg.length-1);
        raw = @str.substring(@currentOffset, idx+1);
        @currentOffset = idx+1;
        # Always canonicalize the tokenized name to lower case
        return { type: 'tag', name: name.toLowerCase(), arg: arg, raw: raw }
      else
        # We don't like this tag, so we just return the current text
        # element, advance by one, and continue.
        @currentOffset++
        return { type: 'text', text: '[' }
    else
      idx = @str.indexOf('[', @currentOffset)
      if idx < 0
        # last text token
        tok = { type: 'text', text: @str.substring(@currentOffset) }
        @currentOffset = @str.length;
        return tok;
      else
        tok = { type: 'text', text: @str.substring(@currentOffset, idx) }
        @currentOffset = idx
        return tok

# A node in a BBCode document.
class BBNode
  constructor: ->
    @parent = null
    @children = []

  # Receives notification that a child tag has been found. This is sent prior to
  # the tag being sent an onStartTag event and may be used to prevent the tag
  # event from being sent at all. If this node doesn't accept children, this
  # may instead return false, which will halt further processing and likely
  # cause an onText event.
  onChildTag: (event) ->
    false

  # Receives notification that an end tag was received. The end tag may or may
  # not correspond to the opening tag.
  onEndTag: (event) ->
    false

  onText: (event) ->
    @appendText(event.text)

  appendChild: (child) ->
    if child.parent != null
      throw new Error("Attempting to add child that already has a parent")
    child.parent = this
    @children.push(child)
    child

  appendText: (text) ->
    @appendChild(new BBText(text))

  # Convert this node to HTML.
  toHTML: ->
    # Assume all our children do something
    html = []
    @children.forEach (child) ->
      html.push(child.toHTML())
    html.join('')

class BBElement extends BBNode
  constructor: (start, end, nests = true) ->
    super()
    @htmlStart = start
    @htmlEnd = end
    @nests = nests

  onChildTag: (event) ->
    @nests

  toHTML: ->
    @htmlStart + super + @htmlEnd

class BBImgElement extends BBNode
  constructor: (rawStart) ->
    super
    @rawStart = rawStart
    @url = []
  onChildTag: (event) ->
    false
  onText: (event) ->
    @url.push(event.text)
  onEndTag: (event) ->
    if event.tag == 'img'
      @rawEnd = event.raw
    else
      @rawEnd = ""
  toHTML: ->
    url = @url.join('')
    if isValidURL(url)
      "<img src=\"#{escapeHTMLAttr(url)}\">"
    else
      escapeHTML(@rawStart + url + @rawEnd)

class BBText extends BBNode
  data: ""
  constructor: (data) ->
    super()
    @data = data
  toHTML: ->
    escapeHTML @data

# Root of the BBCode document.
class BBDocument extends BBNode
  constructor: ->
    super
  onChildTag: (event) ->
    true
  toHTML: ->
    # FIXME: This won't work with [code] and [pre]
    convertNewlinesToHTML(super())

# Parse state.
class BBParse extends BBNode
  constructor: (parser) ->
    @parser = parser

  parse: (str) ->
    @doc = new BBDocument()
    tokenizer = new TagTokenizer(str)
    activeTag = null
    @tagStack = []
    @activeNode = @doc
    while tokenizer.hasNext()
      tok = tokenizer.next()
      switch tok.type
        when 'tag'
          # See what we can do with this
          tag = @parser.findTag(tok.name)
          if tag?
            # Counts, send it to the tag handler
            event = new TagEvent this, tok
            # First, see if the currently active tag allows children
            if @activeNode.onChildTag(event)
              child = tag.onStartTag(event)
              if child?
                @tagStack.push {'name': tok.name, 'tag': tag, 'node': child}
                activeTag = tag
                @activeNode.appendChild child
                @activeNode = child
                continue
          # If we've fallen through any of the above, we're not handling the
          # tag, so treat it as a "dead" tag.
          @onDeadTag(tok.raw)
        when 'text'
          @activeNode.onText new TextEvent(this, tok.text);
        when 'endtag'
          # If this is an end tag, make sure it's an end tag for something that's
          # actually open.
          found = false
          if @tagStack.length > 0
            for i in [(@tagStack.length-1)..0]
              if @tagStack[i].name == tok.name
                # Found the tag this is closing. Everything above this should
                # receive a close event and we close down to this tag.
                found = true
                event = new TagEvent this, tok
                for j in [(@tagStack.length-1)..i]
                  @tagStack[j].node.onEndTag(event)
                # And rip off the end of the tag stack
                @tagStack.length = i
                if @tagStack.length > 0
                  @activeNode = @tagStack[@tagStack.length-1].node
                else
                  @activeNode = @doc
                break
          @onDeadTag(tok.raw) unless found
    @doc

  onDeadTag: (raw) ->
    # Some future version may do something different, this just does this:
    @activeNode.onText(new TextEvent(this, raw))

class Smiley
  constructor: (options) ->
    {@title, @image, @emoji, @match} = options
    if 'size' of options
      @imageWidth = options.size[0]
      @imageHeight = options.size[1]
    if typeof @match == 'string'
      @regexp = new RegExp(@match, 'g')
    else
      patterns = @match.map (pattern) ->
        pattern.replace(/([\\\[\]^${}.?+*()-])/g, '\\$1')
      @regexp = new RegExp(patterns.join('|'), 'g')
    if @emoji?
      if typeof @emoji == 'number'
        if @emoji > 0xFFFF
          high = Math.floor((@emoji - 0x10000) / 0x400) + 0xD800
          low = (@emoji - 0x10000) % 0x400 + 0xDC00
          @replacement = String.fromCharCode(high) + String.fromCharCode(low)
        else
          @replacement = String.fromCharCode(@emoji)
      else
        @replacement = @emoji
    else
      @replacement = "(oops)"
  replace: (text) ->
    text.replace @regexp, @replacement

class BBCodeParser
  constructor: ->
    # Clone the tags as a new object since they may be altered.
    @tags = {}
    for name, tag of BBCodeParser.DEFAULT_TAGS
      @tags[name] = tag
    @smileys = BBCodeParser.DEFAULT_SMILIES.slice()

  @ROOT_TAG: Tag
  @DEFAULT_TAGS:
    'url': new URLTag(),
    'img': new ImgTag(),
#    'quote': QuoteTag,
#    'pre': PreTag,
#    'code': CodeTag,
    'b': new SimpleTag("b"),
    'i': new SimpleTag("i"),
    'u': new SimpleTag("u"),
    's': new SimpleTag("strike"),
    'sub': new SimpleTag("sub"),
    'super': new SimpleTag("super")

  # Built-in smilies based on Emoji, I guess.
  @DEFAULT_SMILIES: [
    # How hard could this be? Well, Apple fucks up WHITE SMILING FACE (IMHO),
    # so instead I'm going to go with SMILING FACE WITH SMILING EYES.
    # (Aren't these names weird?)
    new Smiley({"title": "Smile", "emoji": 0x1F60A, "match": ":-?\\)"})
    new Smiley({"title": "Big Grin", "emoji": 0x1F601, "match": ":-?D"})
    new Smiley({"title": "Sad", "emoji": 0x1F622, "match": ":-?\\("})
    new Smiley({"title": "Cool", "emoji": 0x1F60E, "match": "8-?\\)"})
  ]

  # Sets whether or not to use &lt;em&gt; and &lt;strong&gt; instead of
  # &lt;i&gt; and &lt;b&gt;. It's debatable which is correct.
  #
  setUseEmStrong: (useEmStrong) ->
    if (useEmStrong)
      @tags['i'] = new SimpleTag("em")
      @tags['b'] = new SimpleTag("strong")
    else
      @tags['i'] = BBCodeParser.DEFAULT_TAGS['i']
      @tags['b'] = BBCodeParser.DEFAULT_TAGS['b']

  findTag: (name) ->
    name = name.toLowerCase()
    if name of @tags then @tags[name] else null

  parse: (str) ->
    str ?= "null"
    new BBParse(this).parse(str.toString())

  replaceSmileys: (html) ->
    for smiley in @smileys
      html = smiley.replace(html)
    html

  transform: (str) ->
    @replaceSmileys(@parse(str).toHTML())

defaultParser = new BBCodeParser()

bbcode = (str) ->
  defaultParser.parse(str).toHTML()
  #defaultParser.transform(str)

bbcode.escapeHTML = escapeHTML
bbcode.escapeHTMLAttr = escapeHTMLAttr

exports.bbcode = bbcode
exports.Tag = Tag
exports.BBCodeParser = BBCodeParser
exports.BBNode = BBNode
exports.BBDocument = BBDocument

if (module.parent == null)
  # called directly, translate input files into HTML
  files = [];
  # TODO (maybe): Parse args
  for i in [2..process.argv.length-1]
    files.push(process.argv[i])
  fs = require('fs');
  files.forEach (f) ->
    console.log("Reading %s...", f)
    process.stdout.write(defaultParser.parse(fs.readFileSync(f)))