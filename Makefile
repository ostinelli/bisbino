EBIN_DIR := ebin
SRC_DIR := src
INCLUDE_DIR := include
ERLC := erlc
ERLC_FLAGS := -W -I $(INCLUDE_DIR) -o $(EBIN_DIR)

all:
	@mkdir -p $(EBIN_DIR)
	$(ERLC) $(ERLC_FLAGS) $(SRC_DIR)/*.erl
	@cp $(SRC_DIR)/bisbino.app.src $(EBIN_DIR)/bisbino.app
	
clean:
	@rm -rf $(EBIN_DIR)/*
	@rm -f erl_crash.dump
	
debug:
	@mkdir -p $(EBIN_DIR)
	$(ERLC) -D log_debug $(ERLC_FLAGS) $(SRC_DIR)/*.erl
	@cp $(SRC_DIR)/bisbino.app.src $(EBIN_DIR)/bisbino.app
