package main

import "core:encoding/ansi"
import "core:fmt"
import "core:testing"

Check_Error :: enum {
	None,
	No_Root,
	Non_Linear_Variable,
	Unbound_Reference,
}

@(private = "file")
Context :: struct {
	definition_names: map[string]bool,
	variable_count:   map[string]Variable_Info,
	def_name:         string,
	err_ctx:          ^Error_Context,
}

@(private = "file")
Variable_Info :: struct {
	count:    int,
	position: Position,
}

check :: proc(defs: map[string]Definition) -> (err_ctx: Error_Context, err: Check_Error) {
	err_ctx = {1, 1, 1}
	ctx := Context {
		definition_names = make(map[string]bool),
		variable_count   = make(map[string]Variable_Info),
		err_ctx          = &err_ctx,
	}
	defer delete(ctx.definition_names)
	defer delete(ctx.variable_count)
	context.user_ptr = &ctx

	if "root" not_in defs {
		error("no `@root` definition")
		return err_ctx, .No_Root
	}

	for name in defs {
		ctx.definition_names[name] = true
	}

	for _, &def in defs {
		ctx.def_name = def.name
		check_definition(&def) or_return
		clear(&ctx.variable_count)
	}

	return err_ctx, .None
}

@(private = "file")
check_definition :: proc(def: ^Definition) -> (err: Check_Error) {
	check_term(def.root) or_return

	for redex in def.redexes {
		check_term(redex.left) or_return
		check_term(redex.right) or_return
	}

	check_linearity(def) or_return

	return .None
}

@(private = "file")
check_term :: proc(term: ^Term) -> (err: Check_Error) {
	ctx := cast(^Context)context.user_ptr
	switch term.kind {
	case .VAR:
		name := term.payload.(Var_Payload).name

		info := ctx.variable_count[name]
		info.count += 1
		info.position = term.pos
		ctx.variable_count[name] = info

		if info.count > 2 {
			ctx.err_ctx^ = {info.position.line, info.position.column, info.position.len}

			error(
				"in definition `@%s`, the variable `%s` is referenced more than twice (%d)",
				ctx.def_name,
				name,
				info.count,
			)
			return .Non_Linear_Variable
		}
	case .ERA, .NUM:
	case .REF:
		name := term.payload.(Var_Payload).name
		if name not_in ctx.definition_names {
			ctx.err_ctx^ = {term.pos.line, term.pos.column, term.pos.len}
			error("in definition `@%s`, the reference `@%s` is not defined", ctx.def_name, name)
			return .Unbound_Reference
		}
	case .CON, .DUP, .OPE, .SWI:
		node_payload: Node_Payload
		if term.kind == .OPE do node_payload = term.payload.(Op_Payload).node
		else do node_payload = term.payload.(Node_Payload)
		check_term(node_payload.left) or_return
		check_term(node_payload.right) or_return
	}

	return .None
}

@(private = "file")
check_linearity :: proc(def: ^Definition) -> (err: Check_Error) {
	ctx := cast(^Context)context.user_ptr
	for var, info in ctx.variable_count {
		if info.count != 2 {
			ctx.err_ctx^ = {info.position.line, info.position.column, info.position.len}
			error(
				"in definition `@%s`, the variable `%s` has %d references, expected 2",
				def.name,
				var,
				info.count,
			)
			return .Non_Linear_Variable
		}
	}

	return .None
}

@(private = "file")
error :: proc(msg: string, args: ..any) {
	ctx := cast(^Context)context.user_ptr

	fmt.eprint(ansi.CSI + ansi.FG_RED + ansi.SGR + "Error" + ansi.CSI + ansi.RESET + ansi.SGR)
	fmt.eprintf(" (%d:%d): ", ctx.err_ctx.line, ctx.err_ctx.column)
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
}

// ** Testing **
@(test)
test_check_succeed :: proc(t: ^testing.T) {
	input := `
        @root = a 
            & CON(ERA(), DUP(c, CON(d, DUP(c, d)))) 
            ~ CON(a, DUP(e, CON(b, DUP(e, b))))
    `

	tokenizer := make_tokenizer(input)
	defer delete_tokenizer(&tokenizer)

	tokens, token_ok := tokenize(&tokenizer)
	testing.expect(t, token_ok, "Tokenizing should succeed")

	parser := make_parser(tokens)
	defer delete_parser(&parser)

	definitions, parse_ok := parse(&parser)

	testing.expect(t, parse_ok, "Parsing should succeed")

	_, err := check(definitions)

	testing.expectf(t, err == .None, "Expected %v, got %v", Check_Error.None, err)
}

@(test)
test_check_non_linear_variable_one :: proc(t: ^testing.T) {
	input := `
        @root = a
    `

	tokenizer := make_tokenizer(input)
	defer delete_tokenizer(&tokenizer)

	tokens, token_ok := tokenize(&tokenizer)
	testing.expect(t, token_ok, "Tokenizing should succeed")

	fmt.println(tokens)

	parser := make_parser(tokens)
	defer delete_parser(&parser)

	definitions, parse_ok := parse(&parser)

	fmt.println(definitions)

	testing.expect(t, parse_ok, "Parsing should succeed")

	_, err := check(parser.definitions)

	testing.expectf(
		t,
		err == .Non_Linear_Variable,
		"Expected %v, got %v",
		Check_Error.Non_Linear_Variable,
		err,
	)
}


@(test)
test_check_non_linear_variable_three :: proc(t: ^testing.T) {
	input := `
        @root = a & CON(b, c) ~ DUP(b, a)
    `

	tokenizer := make_tokenizer(input)
	defer delete_tokenizer(&tokenizer)

	tokens, token_ok := tokenize(&tokenizer)
	testing.expect(t, token_ok, "Tokenizing should succeed")

	parser := make_parser(tokens)
	defer delete_parser(&parser)

	definitions, parse_ok := parse(&parser)

	testing.expect(t, parse_ok, "Parsing should succeed")

	_, err := check(definitions)

	testing.expectf(
		t,
		err == .Non_Linear_Variable,
		"Expected %v, got %v",
		Check_Error.Non_Linear_Variable,
		err,
	)
}

@(test)
test_check_Unbound_Reference :: proc(t: ^testing.T) {
	input := `
        @root = a & @first ~ CON(ERA(), a)
    `

	tokenizer := make_tokenizer(input)
	defer delete_tokenizer(&tokenizer)

	tokens, token_ok := tokenize(&tokenizer)
	testing.expect(t, token_ok, "Tokenizing should succeed")

	parser := make_parser(tokens)
	defer delete_parser(&parser)

	definitions, parse_ok := parse(&parser)

	testing.expect(t, parse_ok, "Parsing should succeed")

	_, err := check(definitions)

	testing.expectf(
		t,
		err == .Unbound_Reference,
		"Expected %v, got %v",
		Check_Error.Unbound_Reference,
		err,
	)
}
