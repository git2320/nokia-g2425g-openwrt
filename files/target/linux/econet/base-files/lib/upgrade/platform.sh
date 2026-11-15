platform_check_image() {
	local board=$(board_name)

	case "$board" in
	chinamobile,gs3101|\
	nokia,g-2425g-a|\
	dasan,h660gm-a-airtel|\
	dasan,h660gm-a-generic|\
	jiofiber,jcow407|\
	jiofiber,jcow414)
		return 0
		;;
	esac

	return 1
}

platform_do_upgrade() {
	local board=$(board_name)

	case "$board" in
	chinamobile,gs3101|\
	nokia,g-2425g-a|\
	dasan,h660gm-a-airtel|\
	dasan,h660gm-a-generic|\
	jiofiber,jcow407|\
	jiofiber,jcow414)
		# The Nokia slot layout is: linux_kernel (4 MiB) followed by the
		# "ubi" partition that the runtime UBI volume lives on, both inside
		# the stock "linux" slot. CI_UBIPART must name that partition
		# explicitly; nand_do_upgrade defaults to "ubi" but making it
		# explicit keeps sysupgrade paired with the DTS.
		CI_KERNPART="linux_kernel"
		CI_UBIPART="ubi"
		nand_do_upgrade "$1"
		;;
	esac
}
