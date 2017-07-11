module ExStatement exposing (..)

import Ast
import Ast.Statement exposing (..)
import Ast.Expression exposing (..)
import Ast.BinOp exposing (operators)
import ExContext exposing (Context, Definition, indent, deindent, onlyWithoutFlag)
import ExExpression
import ExType
import Helpers exposing (..)
import List exposing (..)
import Dict exposing (Dict)
import Regex exposing (..)
import Helpers exposing (..)
import Debug exposing (crash)


type ElchemyComment
    = Doc String
    | Ex String
    | Normal String
    | Flag String


moduleStatement : Statement -> Context
moduleStatement s =
    case s of
        ModuleDeclaration names exports ->
            ExContext.empty (String.join "." names) exports

        other ->
            crash "First statement must be module declaration"


elixirS : Context -> Statement -> ( Context, String )
elixirS c s =
    case s of
        InfixDeclaration _ _ _ ->
            ( c, "" )

        TypeDeclaration (TypeConstructor [ name ] _) types ->
            (,) c <|
                (ind c.indent)
                    ++ "@type "
                    ++ toSnakeCase True name
                    ++ " :: "
                    ++ (map (ExType.uniontype c) types |> String.join " | ")
                    ++ "\n"

        TypeAliasDeclaration _ _ ->
            ( c, "" )

        (FunctionTypeDeclaration name ((TypeApplication _ _) as t)) as def ->
            let
                definition =
                    getTypeDefinition def
            in
                (,) (addTypeDefinition c name definition) <|
                    case isOperator name of
                        Builtin ->
                            -- TODO implement operator specs
                            ""

                        Custom ->
                            -- onlyWithoutFlag c
                            -- "nospec0"
                            -- name
                            -- ((ind c.indent)
                            --     ++ "@spec "
                            --     ++ translateOperator name
                            --     ++ (ExType.typespec0 c t)
                            -- )
                            onlyWithoutFlag c
                                "nospec"
                                name
                                ""
                                ++ ((ind c.indent)
                                        ++ "@spec "
                                        ++ translateOperator name
                                        ++ (ExType.typespec c t)
                                   )

                        None ->
                            -- onlyWithoutFlag c
                            --     "nospec0"
                            --     name
                            --     ((ind c.indent)
                            --         ++ "@spec "
                            --         ++ toSnakeCase True name
                            --         ++ (ExType.typespec0 c t)
                            --     )
                            onlyWithoutFlag c
                                "nospec"
                                name
                                ((ind c.indent)
                                    ++ "@spec "
                                    ++ toSnakeCase True name
                                    ++ (ExType.typespec c t)
                                )

        (FunctionTypeDeclaration name t) as def ->
            let
                definition =
                    getTypeDefinition def
            in
                (,) (addTypeDefinition c name definition) <|
                    case isOperator name of
                        Builtin ->
                            -- TODO implement operator specs
                            ""

                        Custom ->
                            onlyWithoutFlag c
                                name
                                "nospec"
                                ((ind c.indent)
                                    ++ "@spec "
                                    ++ translateOperator name
                                    ++ (ExType.typespec c t)
                                )

                        None ->
                            onlyWithoutFlag c
                                name
                                "nospec"
                                ((ind c.indent)
                                    ++ "@spec "
                                    ++ toSnakeCase True name
                                    ++ (ExType.typespec c t)
                                )

        (FunctionDeclaration name args body) as fd ->
            (,) c <| handleFunctionDeclaration c name args body

        Comment content ->
            handleComment c content

        -- That's not a real import. In elixir it's called alias
        ImportStatement path Nothing Nothing ->
            (,) c <|
                (ind c.indent)
                    ++ "alias "
                    ++ modulePath path

        ImportStatement path (Just asName) Nothing ->
            (,) c <|
                (ind c.indent)
                    ++ "alias "
                    ++ modulePath path
                    ++ ", as: "
                    ++ asName

        ImportStatement path Nothing (Just (SubsetExport exports)) ->
            (,) c <|
                (ind c.indent)
                    ++ "import "
                    ++ modulePath path
                    ++ ", only: ["
                    ++ (map subsetExport exports |> foldl (++) [] |> String.join ",")
                    ++ "]"

        ImportStatement path Nothing (Just AllExport) ->
            (,) c <|
                (ind c.indent)
                    ++ "import "
                    ++ modulePath path

        s ->
            (,) c <|
                notImplemented "statement" s


handleFunctionDeclaration : Context -> String -> List Expression -> Expression -> String
handleFunctionDeclaration c name args body =
    let
        returns t =
            c.definitions
                |> Dict.get name
                |> Maybe.map (.def >> ExType.hasReturnedType t)
                |> Maybe.withDefault False

        typeDefinition =
            (c.definitions
                |> Dict.get name
                |> Maybe.map
                    (.def
                        >> typeAplicationToList
                    )
                |> Maybe.withDefault []
                |> map typeAplicationToList
            )
    in
        if name == "meta" && args == [] then
            ExExpression.generateMeta body
        else
            case body of
                Access (Variable ("Native" :: rest)) [ call ] ->
                    ExExpression.generateFfi
                        c
                        name
                        typeDefinition
                        (Application
                            (Application (Variable [ "ffi" ])
                                (String (String.join "." rest))
                            )
                            (String call)
                        )

                (Application (Application (Variable [ "io" ]) _) _) as app ->
                    if returns (TypeConstructor [ "Cmd" ] ([ TypeVariable "a" ])) then
                        ExExpression.generateFfi
                            c
                            name
                            typeDefinition
                            app
                    else
                        Debug.crash "io has to return Cmd a"

                (Application (Application (Variable [ "ffi" ]) _) _) as app ->
                    ExExpression.generateFfi
                        c
                        name
                        typeDefinition
                        app

                (Application (Application (Variable [ "tryFfi" ]) _) _) as app ->
                    if returns (TypeConstructor [ "Result" ] ([ TypeConstructor [ "String" ] [], TypeVariable "a" ])) then
                        ExExpression.generateFfi
                            c
                            name
                            typeDefinition
                            app
                    else
                        Debug.crash "io has to return `Result String a`"

                Case vars expressions ->
                    if ExExpression.flattenCommas vars == args then
                        ExExpression.genOverloadedFunctionDefinition
                            c
                            name
                            args
                            body
                            expressions
                    else
                        ExExpression.genFunctionDefinition
                            c
                            name
                            args
                            body

                _ ->
                    ExExpression.genFunctionDefinition
                        c
                        name
                        args
                        body


handleComment : Context -> String -> ( Context, String )
handleComment c content =
    case getCommentType content of
        Doc content ->
            (,) c <|
                (ind c.indent)
                    ++ "@doc \"\"\"\n "
                    ++ (content
                            |> String.lines
                            |> map (maybeDoctest c)
                            |> map (Helpers.escape)
                            |> map (flip (++) (ind c.indent))
                            |> map trimIndentations
                            |> String.join ""
                            -- Drop an unnecessary \n at the end
                            |> String.dropRight 1
                       )
                    ++ (ind c.indent)
                    ++ "\"\"\""

        Ex content ->
            (,) c <|
                (content
                    |> String.split "\n"
                    |> map String.trim
                    |> String.join "\n"
                    |> indAll c.indent
                )

        Flag content ->
            flip (,) "" <|
                (content
                    |> Regex.split All (regex "\\s+")
                    |> map (String.split ":+")
                    |> filterMap
                        (\flag ->
                            case flag of
                                [ k, v ] ->
                                    Just ( k, v )

                                [ "" ] ->
                                    Nothing

                                a ->
                                    crash ("Wrong flag format " ++ toString a)
                        )
                    |> foldl (ExContext.addFlag) c
                )

        Normal content ->
            (,) c <|
                (content
                    |> prependAll ("# ")
                    |> indAll c.indent
                )


getCommentType : String -> ElchemyComment
getCommentType comment =
    [ ( "^\\sex\\b", (Ex) )
    , ( "^\\|", (Doc) )
    , ( "^\\sflag\\b", (Flag) )
    ]
        |> List.map (\( a, b ) -> ( Regex.regex a, b ))
        |> List.foldl findCommentType (Normal comment)


findCommentType : ( Regex.Regex, String -> ElchemyComment ) -> ElchemyComment -> ElchemyComment
findCommentType ( regex, commentType ) acc =
    case acc of
        Normal content ->
            if Regex.contains regex content then
                commentType <|
                    Regex.replace (Regex.AtMost 1) regex (always "") content
            else
                Normal content

        other ->
            other


subsetExport : ExportSet -> List String
subsetExport exp =
    case exp of
        TypeExport _ _ ->
            []

        FunctionExport name ->
            [ "{:'" ++ name ++ "', 0}" ]

        _ ->
            crash ("You can't export " ++ toString exp)


maybeDoctest : Context -> String -> String
maybeDoctest c line =
    if String.startsWith (ind (c.indent + 1)) ("\n" ++ line) then
        case Ast.parseExpression Ast.BinOp.operators (String.trim line) of
            Ok ( _, _, BinOp (Variable [ "==" ]) l r ) ->
                ind (c.indent + 2)
                    ++ "iex> import "
                    ++ c.mod
                    ++ ind (c.indent + 2)
                    ++ "iex> "
                    ++ ExExpression.elixirE c l
                    ++ ind (c.indent + 2)
                    ++ ExExpression.elixirE c r

            _ ->
                line
    else
        line


getTypeDefinition : Statement -> Definition
getTypeDefinition a =
    case a of
        FunctionTypeDeclaration name t ->
            let
                arity =
                    typeAplicationToList t |> length
            in
                Definition (arity - 1) t

        _ ->
            Debug.crash "It's not a type declaration"


addTypeDefinition : Context -> String -> Definition -> Context
addTypeDefinition c name d =
    { c
        | definitions =
            Dict.insert name
                d
                c.definitions
    }


typeAplicationToList : Type -> List Type
typeAplicationToList application =
    case application of
        TypeApplication left right ->
            [ left ] ++ typeAplicationToList right

        other ->
            [ other ]
