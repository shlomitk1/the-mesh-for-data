ROOT_DIR:=../..
include $(ROOT_DIR)/Makefile.env
include $(ROOT_DIR)/hack/make-rules/tools.mk

.PHONY: loadpolicy
loadpolicy: $(TOOLBIN)/kubectl
	./deploy.sh loadpolicy $(ARGS)

.PHONY: loaddata
loaddata: $(TOOLBIN)/kubectl
	./deploy.sh loaddata $(ARGS)

.PHONY: unloadpolicy
unloadpolicy: $(TOOLBIN)/kubectl
	./deploy.sh unloadpolicy $(ARGS)

.PHONY: unloaddata
unloaddata: $(TOOLBIN)/kubectl
	./deploy.sh unloaddata $(ARGS)
