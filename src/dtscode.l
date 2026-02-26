/******************************************************************************
 *
 * Copyright (C) 1997-2020 by Dimitri van Heesch.
 *
 * Permission to use, copy, modify, and distribute this software and its
 * documentation under the terms of the GNU General Public License is hereby
 * granted. No representations are made about the suitability of this software
 * for any purpose. It is provided "as is" without express or implied warranty.
 * See the GNU General Public License for more details.
 *
 * Documents produced by Doxygen are derivative works derived from the
 * input used in their production; they are not affected by this license.
 *
 */

%option never-interactive
%option prefix="dtscodeYY"
%option noyywrap
%option nounput
%option reentrant
%option extra-type="struct dtscodeYY_state *"
%top{
#include <stdint.h>
// forward declare yyscan_t to improve type safety
#define YY_TYPEDEF_YY_SCANNER_T
struct yyguts_t;
typedef yyguts_t *yyscan_t;
}

%{

#include <stdio.h>

#include "dtscode.h"

#include "entry.h"
#include "doxygen.h"
#include "outputlist.h"
#include "util.h"
#include "membername.h"
#include "searchindex.h"
#include "config.h"
#include "filedef.h"
#include "tooltip.h"
#include "message.h"
#include "debug.h"

#define YY_NEVER_INTERACTIVE 1
#define YY_NO_INPUT 1
#define YY_NO_UNISTD_H 1

struct dtscodeYY_state
{
     OutputCodeList * code = nullptr;
     const char   *inputString = nullptr; //!< the code fragment as text
     int           inputPosition = 0;     //!< read offset during parsing
     QCString      fileName;
     int           inputLines = 0;        //!< number of line in the code fragment
     int           yyLineNr = 1;          //!< current line number
     bool          insideCodeLine = false;
     const Definition   *searchCtx = nullptr;

     bool          stripCodeComments = true;
     bool          exampleBlock = false;
     QCString      exampleName;
     QCString      classScope;

     std::unique_ptr<FileDef> exampleFileDef;
     const FileDef    *sourceFileDef = nullptr;
     bool          lineNumbers = FALSE;
     const Definition *currentDefinition = nullptr;
     const MemberDef  *currentMemberDef = nullptr;
     bool          includeCodeFragment = false;
     const char   *currentFontClass = nullptr;
};

[[maybe_unused]] static const char *stateToString(int state);

static void setCurrentDoc(yyscan_t yyscanner,const QCString &anchor);
static void startCodeLine(yyscan_t yyscanner);
static void endFontClass(yyscan_t yyscanner);
static void endCodeLine(yyscan_t yyscanner);
static void nextCodeLine(yyscan_t yyscanner);
static void codifyLines(yyscan_t yyscanner,const char *text);
static void startFontClass(yyscan_t yyscanner,const char *s);
static int countLines(yyscan_t yyscanner);
static int yyread(yyscan_t yyscanner,char *buf,int max_size);

#undef YY_INPUT
#define YY_INPUT(buf,result,max_size) result=yyread(yyscanner,buf,max_size);

// otherwise the filename would be the name of the converted file (*.cpp instead of *.l)
static inline const char *getLexerFILE() {return __FILE__;}
#include "doxygen_lex.h"

%}

nl              (\r\n|\r|\n)
idchar          [A-Za-z0-9_+,\.\-@]
directive       ("/dts-v1/"|"/plugin/"|"/memreserve/"|"/include/"|"/delete-node/"|"/delete-property/"|"/bits/")
stringliteral   (\"([^\"\\]|\\.)*\")|('([^'\\]|\\.)*')
phandle         "&"({idchar}+|"{"[^}\n]+"}")
simplecomment   "//".*
commentopen     "/\*"
commentclose    "\*\/"

%x COMMENT

%%

{directive}         {
                        startFontClass(yyscanner,"keyword");
                        codifyLines(yyscanner,yytext);
                        endFontClass(yyscanner);
                    }

{phandle}           {
                        startFontClass(yyscanner,"preprocessor");
                        codifyLines(yyscanner,yytext);
                        endFontClass(yyscanner);
                    }

{stringliteral}     {
                        startFontClass(yyscanner,"stringliteral");
                        codifyLines(yyscanner,yytext);
                        endFontClass(yyscanner);
                    }

{simplecomment}     {
                        startFontClass(yyscanner,"comment");
                        codifyLines(yyscanner,yytext);
                        endFontClass(yyscanner);
                    }

{commentopen}       {
                        startFontClass(yyscanner,"comment");
                        codifyLines(yyscanner,yytext);
                        BEGIN(COMMENT);
                    }

<COMMENT>{commentclose} {
                        codifyLines(yyscanner,yytext);
                        endFontClass(yyscanner);
                        BEGIN(INITIAL);
                    }

<COMMENT>{nl}       {
                        codifyLines(yyscanner,yytext);
                    }

<COMMENT>.          {
                        codifyLines(yyscanner,yytext);
                    }

{idchar}+           {
                        codifyLines(yyscanner,yytext);
                    }

{nl}                {
                        codifyLines(yyscanner,yytext);
                    }

[\x80-\xFF]*        { // keep utf8 characters together...
                        codifyLines(yyscanner,yytext);
                    }

.                   {
                        codifyLines(yyscanner,yytext);
                    }

%%


static void setCurrentDoc(yyscan_t yyscanner,const QCString &anchor)
{
  struct yyguts_t *yyg = (struct yyguts_t*)yyscanner;
  if (Doxygen::searchIndex.enabled())
  {
    if (yyextra->searchCtx)
    {
      Doxygen::searchIndex.setCurrentDoc(yyextra->searchCtx,yyextra->searchCtx->anchor(),false);
    }
    else
    {
      Doxygen::searchIndex.setCurrentDoc(yyextra->sourceFileDef,anchor,true);
    }
  }
}

/*! start a new line of code, inserting a line number if yyextra->sourceFileDef
 * is true. If a definition starts at the current line, then the line
 * number is linked to the documentation of that definition.
 */
static void startCodeLine(yyscan_t yyscanner)
{
  struct yyguts_t *yyg = (struct yyguts_t*)yyscanner;
  if (yyextra->sourceFileDef && yyextra->lineNumbers)
  {
    const Definition *d = yyextra->sourceFileDef->getSourceDefinition(yyextra->yyLineNr);

    if (!yyextra->includeCodeFragment && d && d->isLinkableInProject())
    {
      yyextra->currentDefinition = d;
      yyextra->currentMemberDef = yyextra->sourceFileDef->getSourceMember(yyextra->yyLineNr);
      yyextra->classScope = d->name();
      QCString lineAnchor;
      lineAnchor.sprintf("l%05d",yyextra->yyLineNr);
      if (yyextra->currentMemberDef)
      {
        yyextra->code->writeLineNumber(yyextra->currentMemberDef->getReference(),
                            yyextra->currentMemberDef->getOutputFileBase(),
                            yyextra->currentMemberDef->anchor(),yyextra->yyLineNr,
                            !yyextra->includeCodeFragment);
        setCurrentDoc(yyscanner,lineAnchor);
      }
      else
      {
        yyextra->code->writeLineNumber(d->getReference(),
                            d->getOutputFileBase(),
                            QCString(),yyextra->yyLineNr,
                            !yyextra->includeCodeFragment);
        setCurrentDoc(yyscanner,lineAnchor);
      }
    }
    else
    {
      yyextra->code->writeLineNumber(QCString(),QCString(),QCString(),yyextra->yyLineNr,
                                     !yyextra->includeCodeFragment);
    }
  }

  yyextra->code->startCodeLine(yyextra->yyLineNr);
  yyextra->insideCodeLine=true;

  if (yyextra->currentFontClass)
  {
    yyextra->code->startFontClass(yyextra->currentFontClass);
  }
}

static void endFontClass(yyscan_t yyscanner)
{
  struct yyguts_t *yyg = (struct yyguts_t*)yyscanner;
  if (yyextra->currentFontClass)
  {
    yyextra->code->endFontClass();
    yyextra->currentFontClass=0;
  }
}

static void endCodeLine(yyscan_t yyscanner)
{
  struct yyguts_t *yyg = (struct yyguts_t*)yyscanner;
  endFontClass(yyscanner);
  yyextra->code->endCodeLine();
  yyextra->insideCodeLine=false;
}

static void nextCodeLine(yyscan_t yyscanner)
{
  struct yyguts_t *yyg = (struct yyguts_t*)yyscanner;
  const char *fc = yyextra->currentFontClass;
  if (yyextra->insideCodeLine)
  {
    endCodeLine(yyscanner);
  }
  if (yyextra->yyLineNr<yyextra->inputLines)
  {
    yyextra->currentFontClass = fc;
    startCodeLine(yyscanner);
  }
}

static void codifyLines(yyscan_t yyscanner,const char *text)
{
  struct yyguts_t *yyg = (struct yyguts_t*)yyscanner;
  const char *p=text,*sp=p;
  char c;
  bool done=false;
  while (!done)
  {
    sp=p;
    while ((c=*p++) && c!='\n') { }
    if (c=='\n')
    {
      yyextra->yyLineNr++;
      size_t l = static_cast<size_t>(p-sp-1);
      yyextra->code->codify(QCString(sp,l));
      nextCodeLine(yyscanner);
    }
    else
    {
      yyextra->code->codify(sp);
      done=true;
    }
  }
}

static void startFontClass(yyscan_t yyscanner,const char *s)
{
  struct yyguts_t *yyg = (struct yyguts_t*)yyscanner;
  endFontClass(yyscanner);
  yyextra->code->startFontClass(s);
  yyextra->currentFontClass=s;
}

/*! counts the number of lines in the input */
static int countLines(yyscan_t yyscanner)
{
  struct yyguts_t *yyg = (struct yyguts_t*)yyscanner;
  const char *p=yyextra->inputString;
  char c;
  int count=1;
  while ((c=*p))
  {
    p++ ;
    if (c=='\n') count++;
  }
  if (p>yyextra->inputString && *(p-1)!='\n')
  { // last line does not end with a \n, so we add an extra
    // line and explicitly terminate the line after parsing.
    count++;
  }
  return count;
}

static int yyread(yyscan_t yyscanner,char *buf,int max_size)
{
  struct yyguts_t *yyg = (struct yyguts_t*)yyscanner;
  int inputPosition = yyextra->inputPosition;
  const char *s = yyextra->inputString + inputPosition;
  int c=0;
  while( c < max_size && *s )
  {
    *buf++ = *s++;
    c++;
  }
  yyextra->inputPosition += c;
  return c;
}


// public interface -----------------------------------------------------------

struct DTSCodeParser::Private
{
  yyscan_t yyscanner;
  dtscodeYY_state state;
};

DTSCodeParser::DTSCodeParser() : p(std::make_unique<Private>())
{
  dtscodeYYlex_init_extra(&p->state, &p->yyscanner);
#ifdef FLEX_DEBUG
  dtscodeYYset_debug(Debug::isFlagSet(Debug::Lex_scanner)?1:0,p->yyscanner);
#endif
  resetCodeParserState();
}

DTSCodeParser::~DTSCodeParser()
{
  dtscodeYYlex_destroy(p->yyscanner);
}

void DTSCodeParser::resetCodeParserState()
{
  struct yyguts_t *yyg = (struct yyguts_t*)p->yyscanner;
  yyextra->currentDefinition = nullptr;
  yyextra->currentMemberDef = nullptr;
}

void DTSCodeParser::parseCode(OutputCodeList &codeOutIntf,
               const QCString &/* scopeName */,
               const QCString &input,
               SrcLangExt,
               bool stripCodeComments,
               const CodeParserOptions &options
              )
{
  yyscan_t yyscanner = p->yyscanner;
  struct yyguts_t *yyg = (struct yyguts_t*)yyscanner;

  if (input.isEmpty()) return;

  DebugLex debugLex(Debug::Lex_scanner, __FILE__, options.fileDef() ? qPrint(options.fileDef()->fileName()): nullptr);
  yyextra->fileName          = options.fileDef() ? options.fileDef()->fileName():"";
  yyextra->code              = &codeOutIntf;
  yyextra->inputString       = input.data();
  yyextra->inputPosition     = 0;
  yyextra->currentFontClass  = nullptr;
  yyextra->insideCodeLine    = false;
  yyextra->searchCtx         = options.searchCtx();
  yyextra->yyLineNr          = options.startLine()!=-1 ? options.startLine() : 1;
  yyextra->inputLines        = options.endLine()!=-1   ? options.endLine()+1 : yyextra->yyLineNr + countLines(yyscanner) - 1;
  yyextra->stripCodeComments = stripCodeComments;
  yyextra->exampleBlock      = options.isExample();
  yyextra->exampleName       = options.exampleName();
  yyextra->sourceFileDef     = options.fileDef();
  yyextra->lineNumbers       = options.fileDef() && options.showLineNumbers();

  if (options.isExample() && options.fileDef()==0)
  {
    // create a dummy filedef for the example
    yyextra->exampleFileDef = createFileDef(QCString(),!options.exampleName().isEmpty() ? options.exampleName() : QCString("generated"));
    yyextra->sourceFileDef = yyextra->exampleFileDef.get();
  }

  if (yyextra->sourceFileDef)
  {
    setCurrentDoc(yyscanner,"l00001");
  }

  yyextra->includeCodeFragment = options.inlineFragment();
  // Starts line 1 on the output
  startCodeLine(yyscanner);

  dtscodeYYrestart( nullptr, yyscanner );

  dtscodeYYlex(yyscanner);

  if (yyextra->insideCodeLine)
  {
    endCodeLine(yyscanner);
  }
  if (yyextra->exampleFileDef)
  {
    // delete the temporary file definition used for this example
    yyextra->exampleFileDef.reset();
    yyextra->sourceFileDef=nullptr;
  }
}

//---------------------------------------------------------------------------------

#include "dtscode.l.h"
