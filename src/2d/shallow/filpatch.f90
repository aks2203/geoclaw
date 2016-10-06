! :::::::::::::::::::::::::::: FILPATCH :::::::::::::::::::::::::;
!
!  fill the portion of valbig from rows  nrowst
!                             and  cols  ncolst
!  the patch can also be described by the corners (xlp,ybp) by (xrp,ytp).
!  vals are needed at time t, and level level,
!
!  first fill with  values obtainable from the level level
!  grids. if any left unfilled, then enlarge remaining rectangle of
!  unfilled values by 1 (for later linear interp), and recusively
!  obtain the remaining values from  coarser levels.
!
! :::::::::::::::::::::::::::::::::::::::;:::::::::::::::::::::::;
recursive subroutine filrecur(level,nvar,valbig,aux,naux,t,mx,my, &
                              nrowst,ncolst,ilo,ihi,jlo,jhi,patchOnly,msrc)

    use amr_module, only: nghost, xlower, ylower, xupper, yupper, outunit
    use amr_module, only: xperdom, yperdom, spheredom, hxposs, hyposs
    use amr_module, only: intratx, intraty, iregsz, jregsz
    use amr_module, only: timeSetaux, NEEDS_TO_BE_SET

    use multilayer_module, only: num_layers, rho, eta_init, dry_tolerance

    use geoclaw_module, only: sea_level
    use topo_module, only: topo_finalized

    implicit none

    ! Input
    integer, intent(in) :: level, nvar, naux, mx, my, nrowst, ncolst
    integer, intent(in) :: ilo,ihi,jlo,jhi,msrc
    real(kind=8), intent(in) :: t
    logical  :: patchOnly

    ! Output
    real(kind=8), intent(in out) :: valbig(nvar,mx,my)
    real(kind=8), intent(in out) :: aux(naux,mx,my)

    ! Local storage
    integer  :: clock_start, clock_finish, clock_rate, clock_dif
    integer  :: iplo, iphi, jplo, jphi

    ! Flagging of set cells
    logical :: set
    integer :: i, i_coarse, j_coarse, i_fine, j_fine, n, k
    integer :: i_f, j_f
    integer :: mx_coarse, my_coarse, mx_patch, my_patch
    integer :: unset_indices(4), coarse_indices(4)
    integer :: refinement_ratio_x, refinement_ratio_y, ratio_x,ratio_y
    integer :: layer, i_layer, ico, jco, ii, jj
    real(kind=8) :: dx_fine, dy_fine, dx_coarse, dy_coarse
    real(kind=8) :: xlow_coarse,ylow_coarse, xlow_fine, ylow_fine, xhi_fine,yhi_fine   
    real(kind=8) :: h, b(5), bfine, eta_fine, eta1, eta2, up_slope, down_slope
    real(kind=8) :: h_i, h_j, s1m, s1p, slopex, slopey, xoff, yoff
    real(kind=8) :: hv_fine, v_fine, v_new, divide_mass
    real(kind=8) :: h_fine_average, h_fine, h_count, h_coarse
    real(kind=8)::  xcent_fine,xcent_coarse,ycent_fine,ycent_coarse
    integer(kind=1) :: flaguse(ihi-ilo+1, jhi-jlo+1)

    real(kind=8) :: eta1old, eta2old

    ! Scratch arrays for interpolation
    logical :: fine_flag(nvar, ihi-ilo+2,jhi-jlo + 2)

    logical :: reloop


    ! these are dimensioned at fine size since coarse grid size cant be larger (incl. the +3 that is )
    real(kind=8) ::  fine_mass(ihi-ilo + 3, jhi-jlo + 3)
    real(kind=8) :: eta_coarse(3)
    real(kind=8) ::    vel_max(ihi-ilo + 3, jhi-jlo + 3)
    real(kind=8) ::    vel_min(ihi-ilo + 3, jhi-jlo + 3)
    real(kind=8) ::   slope(2, ihi-ilo + 3, jhi-jlo + 3)
    integer ::   fine_cell_count(ihi-ilo+3, jhi-jlo + 3)

    integer :: nghost_patch, lencrse

    ! Stack storage
    !  use stack-based scratch arrays instead of alloc, since dont really
    !  need to save beyond these routines, and to allow dynami_coarse memory resizing
    !  use 1d scratch arrays that are potentially the same size as
    !  current grid, since may not coarsen.
    !  need to make it 1d instead of 2 and do own indexing, since
    !  when pass it in to subroutines they treat it as having di_fineerent
    !  dimensions than the max size need to allocate here
    ! the +2 is to expand on coarse grid to enclose fine
    real(kind=8) :: valcrse((ihi-ilo+3) * (jhi-jlo+3) * nvar)   ! NB this is a 1D array 
    real(kind=8) :: auxcrse((ihi-ilo+3) * (jhi-jlo+3) * naux)  


    mx_patch = ihi-ilo + 1 ! nrowp
    my_patch = jhi-jlo + 1 

    dx_fine     = hxposs(level)
    dy_fine     = hyposs(level)

    ! Coordinates of edges of patch (xlp,xrp,ybp,ytp)
    xlow_fine = xlower + ilo * dx_fine
    ylow_fine = ylower + jlo * dy_fine

    ! Fill in the patch as much as possible using values at this level
    ! note that if only a patch, msrc = -1, otherwise a real grid and intfil
    ! uses its boundary list
    ! msrc either -1 (for a patch) or the real grid number
    call intfil(valbig,mx,my,t,flaguse,nrowst,ncolst, ilo,  &
                ihi,jlo,jhi,level,nvar,naux,msrc)

    ! Trimbd returns set = true if all of the entries are filled (=1.).
    ! set = false, otherwise. If set = true, then no other levels are
    ! are required to interpolate, and we return.
    !
    ! Note that the used array is filled entirely in intfil, i.e. the
    ! marking done there also takes  into account the points filled by
    ! the boundary conditions. bc2amr will be called later, after all 4
    ! boundary pieces filled.
    call trimbd(flaguse,mx_patch,my_patch,set,unset_indices)
    ! il,ir,jb,jt = unset_indices(4)

    ! If set is .true. then all cells have been set and we can skip to setting
    ! the remaining boundary cells.  If it is .false. we need to interpolate
    ! some values from coarser levels, possibly calling this routine
    ! recursively.
    if (.not.set) then

        ! Error check
        if (level == 1) then
            write(outunit,*)" error in filrecur - level 1 not set"
            write(outunit,'("start at row: ",i4," col ",i4)') nrowst,ncolst
            print *," error in filrecur - level 1 not set"
            print *," should not need more recursion "
            print *," to set patch boundaries"
            print '("start at row: ",i4," col ",i4)', nrowst,ncolst
            stop
        endif

        ! We begin by initializing the level level arrays, so that we can use
        ! purely recursive formulation for interpolating.
        dx_coarse  = hxposs(level - 1)
        dy_coarse  = hyposs(level - 1)

        ! Adjust unset_indices to account for the patch
        ! isl, isr, jsb, jst
        unset_indices(1) = unset_indices(1) + ilo - 1
        unset_indices(2) = unset_indices(2) + ilo - 1
        unset_indices(3) = unset_indices(3) + jlo - 1
        unset_indices(4) = unset_indices(4) + jlo - 1

        ! Coarsened geometry
        refinement_ratio_x = intratx(level - 1)
        refinement_ratio_y = intraty(level - 1)

        ! New patch rectangle (after we have partially filled it in) but in the
        ! coarse patches [iplo,iphi,jplo,jphi]

        iplo = (unset_indices(1) - refinement_ratio_x + nghost * refinement_ratio_x) &
                                                / refinement_ratio_x - nghost
        iphi = (unset_indices(2) + refinement_ratio_x) / refinement_ratio_x
        jplo = (unset_indices(3) - refinement_ratio_y + nghost * refinement_ratio_y) &
                                                / refinement_ratio_y - nghost
        jphi = (unset_indices(4) + refinement_ratio_y) / refinement_ratio_y
                                                

        xlow_coarse = xlower + iplo * dx_coarse
        ylow_coarse = ylower + jplo * dy_coarse


        ! Coarse grid number of spatial points (nrowc,ncolc)
        mx_coarse   =  iphi - iplo  + 1
        my_coarse   =  jphi - jplo  + 1

        ! Check to make sure we created big enough scratch arrays
        if (mx_coarse > ihi - ilo + 3 .or. &
            my_coarse > jhi - jlo + 3) then

            print *," did not make big enough work space in filrecur "
            print *," need coarse space with mx_coarse,my_coarse ",mx_coarse,my_coarse
            print *," made space for ilo,ihi,jlo,jhi ",ilo,ihi,jlo,jhi
            stop
        endif

        ! Set the aux array values for the coarse grid, this could be done
        ! instead in intfil using possibly already available bathy data from the
        ! grids
        
        if (naux > 0) then
            nghost_patch = 0
            call system_clock(clock_start,clock_rate)
  
            ! update topography if needed
            !if ((num_dtopo>0).and.(topo_finalized.eqv..false.)) then
            !   if ((minval(topotime)<maxval(tfdtopo)).and.(t>=minval(t0dtopo))) then
            if (.not. topo_finalized) then
                call topo_update(t)
                endif

            nghost_patch = 0                           
            lencrse = (ihi-ilo+3)*(jhi-jlo+3)*naux ! set 1 component, not all naux
            do k = 1, lencrse, naux
              auxcrse(k) = NEEDS_TO_BE_SET  ! new system checks initialization before setting aux vals
            end do
            call setaux(nghost_patch, mx_coarse, my_coarse,       &
                        xlow_coarse, ylow_coarse,                 &
                        dx_coarse,dy_coarse,naux,auxcrse)
            call system_clock(clock_finish,clock_rate)
            clock_dif = clock_finish - clock_start
!$OMP ATOMIC            
            timeSetaux = timeSetaux + clock_dif
        endif

        ! Fill in the edges of the coarse grid
        if ((xperdom .or. (yperdom .or. spheredom)) .and. sticksout(iplo,iphi,jplo,jphi)) then
            call prefilrecur(level-1,nvar,valcrse,auxcrse,naux,t, &
                             mx_coarse,my_coarse,1,1,iplo,iphi,jplo,jphi,iplo,iphi,jplo,jphi,.true.)
        else ! when going to coarser patch, no source grid (for now at least) hence -1
            call filrecur(level-1,nvar,valcrse,auxcrse,naux,t,  &
                          mx_coarse,my_coarse,1,1,iplo,iphi,jplo,jphi,.true.,-1)

        endif

        !********* Begin Interpolations **************!
        ratio_y = refinement_ratio_y
        ratio_x = refinement_ratio_x
!         do layer = num_layers, 1, -1 
        ! the number of values in a cell (for now 3: eta, u, v) should be calculated from num_layers and nvar

        ! loop through coarse cells determining intepolation slopes
        ! these will be saved for fine grid loop
        ! prevents finding the same slope possibly lratiox*lratioy times
        ! all fine gid depths will be found before any momentum
        reloop = .false.
        fine_cell_count = 0
        fine_flag = .false.
        fine_mass = 0.d0
        slope = 0.d0

        ! Calculate surface elevation eta using dry limiting
        ! valcrse h values still need to be divided by rho
        do j_coarse = 2, my_coarse-1
            do i_coarse = 2, mx_coarse-1
                b = ( (/ auxcrse(iauxc(i_coarse,j_coarse)), auxcrse(iauxc(i_coarse+1,j_coarse)), &
                        auxcrse(iauxc(i_coarse-1,j_coarse)), auxcrse(iauxc(i_coarse,j_coarse+1)), &
                        auxcrse(iauxc(i_coarse,j_coarse-1)) /) )

                do layer = num_layers, 1, -1
                    h = valcrse(ivalc(3*layer-2,i_coarse,j_coarse)) / rho(layer)
                    if (h < dry_tolerance(layer)) then
                        eta_coarse(2) = eta_init(layer)
                    else
                        eta_coarse(2) = h + b(1)
                    endif

                    do ii = -1, 1, 2
                        h_i = valcrse(ivalc(3*layer-2,i_coarse+ii,j_coarse)) / rho(layer)
                        if (h_i < dry_tolerance(layer)) then
                            eta_coarse(2+ii) = eta_init(layer)
                        else
                            eta_coarse(2+ii) = h_i + b((5+ii)/2)
                        endif
                        b((5+ii)/2) = h_i + b((5+ii)/2)
                    enddo

                    s1p = eta_coarse(3) - eta_coarse(2)
                    s1m = eta_coarse(2) - eta_coarse(1)
                    slopex = min(abs(s1p), abs(s1m)) * sign(1.d0,eta_coarse(3) - eta_coarse(1))
                    if (s1m*s1p <= 0.d0) slopex=0.d0

                    do jj = -1, 1, 2
                        h_j = valcrse(ivalc(3*layer-2, i_coarse, j_coarse +jj)) / rho(layer)
                        if (h_j < dry_tolerance(layer)) then
                            eta_coarse(2+jj) = eta_init(layer)
                        else
                            eta_coarse(2+jj) = h_j + b((9+jj)/2)
                        endif
                        b((9+jj)/2) = h_j + b((9+jj)/2)
                    enddo

                    s1p = eta_coarse(3) - eta_coarse(2)
                    s1m = eta_coarse(2) - eta_coarse(1)
                    slopey = min(abs(s1p), abs(s1m)) * sign(1.d0,eta_coarse(3)-eta_coarse(1))
                    if (s1m*s1p <= 0.d0) slopey=0.d0

                    do jco = 1, ratio_y
                        do ico = 1, ratio_x
                            yoff = (real(jco,kind=8) - 0.5d0) / ratio_y - 0.5d0
                            xoff = (real(ico,kind=8) - 0.5d0) / ratio_x - 0.5d0

                            j_fine = (j_coarse-2) * ratio_y + jco
                            i_fine = (i_coarse-2) * ratio_x + ico
                            
                            j_f = j_fine+ncolst-1
                            i_f = i_fine+nrowst-1
                            
                            bfine = aux(1, i_f, j_f)
                            do i_layer = layer+1, num_layers
                                bfine = bfine + valbig(3*i_layer-2,i_f, j_f)/rho(i_layer)
                            enddo

                            if (flaguse(i_fine, j_fine) == 0) then
                                fine_cell_count(i_coarse, j_coarse) = fine_cell_count(i_coarse, j_coarse) + 1
                                valbig(3*layer-2, i_f, j_f) = (eta_coarse(2) + (xoff * slopex) + &
                                                                (yoff * slopey) - bfine) * rho(layer)
                                valbig(3*layer-2, i_f, j_f) = max(0.d0, valbig(3*layer-2, i_f, j_f))
                                if (valbig(3*layer-2, i_f, j_f) < dry_tolerance(layer)) then
                                    valbig(3*layer-1, i_f, j_f) = 0.d0
                                    valbig(3*layer, i_f, j_f) = 0.d0
                                endif
                                fine_mass(i_coarse,j_coarse) = fine_mass(i_coarse,j_coarse) + valbig(3*layer-2, i_f, j_f)

                                if (valbig(3*layer-2, i_f, j_f) < dry_tolerance(layer)) then
                                    fine_flag(1,i_coarse,j_coarse) = .true.
                                    reloop = .true.
                                endif

                            endif
                        enddo
                    enddo
                    b(1) = b(1) + h


                ! Momentum Interpolation
                    do n = 3*layer - 1, 3*layer
                        ! Determine slopes for interpolation
                        down_slope = (valcrse(ivalc(n,i_coarse,j_coarse)) - valcrse(ivalc(n,i_coarse-1,j_coarse)))
                        up_slope   = (valcrse(ivalc(n,i_coarse+1,j_coarse)) - valcrse(ivalc(n,i_coarse,j_coarse)))
                        if (up_slope * down_slope > 0.d0) then
                            slope(1,i_coarse,j_coarse) = min(abs(up_slope), abs(down_slope)) *    &
                                              sign(1.d0, valcrse(ivalc(n,i_coarse+1,j_coarse))    &
                                               - valcrse(ivalc(n,i_coarse-1,j_coarse)))
                        endif

                        down_slope = (valcrse(ivalc(n,i_coarse,j_coarse)) - valcrse(ivalc(n,i_coarse,j_coarse-1)))
                        up_slope   = (valcrse(ivalc(n,i_coarse,j_coarse+1)) - valcrse(ivalc(n,i_coarse,j_coarse)))
                        if (up_slope * down_slope > 0.d0) then
                            slope(2,i_coarse,j_coarse) = min(abs(up_slope), abs(down_slope))       &
                                             * sign(1.d0, valcrse(ivalc(n,i_coarse,j_coarse+1))    &
                                              - valcrse(ivalc(n,i_coarse,j_coarse-1)))
                        endif

                        ! Set initial values for max/min of current field
                        if (valcrse(ivalc(1,i_coarse,j_coarse)) > dry_tolerance(layer)) then
                            vel_max(i_coarse,j_coarse) = valcrse(ivalc(n,i_coarse,j_coarse)) /    &
                                                         valcrse(ivalc(1,i_coarse,j_coarse))
                            vel_min(i_coarse,j_coarse) = valcrse(ivalc(n,i_coarse,j_coarse)) /    &
                                                         valcrse(ivalc(1,i_coarse,j_coarse))
                        else
                            vel_min(i_coarse,j_coarse) = 0.d0
                            vel_max(i_coarse,j_coarse) = 0.d0
                        endif

                        ! Look for bounds on velocity around each cell
                        ! Necessary since we are interpolating momentum linearly
                        ! but not interpolating depth linearly
                        do i =-1,1,2
                            if (valcrse(ivalc(1,i_coarse + i,j_coarse)) > dry_tolerance(layer)) then
                                vel_max(i_coarse,j_coarse) =  max(vel_max(i_coarse,j_coarse),      &
                                                    valcrse(ivalc(n,i_coarse + i,j_coarse)) /      &
                                                    valcrse(ivalc(1,i_coarse + i,j_coarse)))
                                vel_min(i_coarse,j_coarse) = min(vel_min(i_coarse,j_coarse),       &
                                                    valcrse(ivalc(n,i_coarse + i,j_coarse)) /      &
                                                    valcrse(ivalc(1,i_coarse + i,j_coarse)))
                            endif

                            if (valcrse(ivalc(1,i_coarse,j_coarse + i)) > dry_tolerance(layer)) then
                                vel_max(i_coarse,j_coarse) = max(vel_max(i_coarse,j_coarse),       &
                                                      valcrse(ivalc(n,i_coarse,j_coarse + i)) /    &
                                                      valcrse(ivalc(1,i_coarse,j_coarse + i)))
                                vel_min(i_coarse,j_coarse) = min(vel_min(i_coarse,j_coarse),       &
                                                      valcrse(ivalc(n,i_coarse,j_coarse + i)) /    &
                                                      valcrse(ivalc(1,i_coarse,j_coarse + i)))

                            endif
                        enddo


                    ! Determine momentum in fine cells
                        do j_fine = 1, my_patch
                            ycent_coarse = ylow_coarse + (j_coarse-.5d0)*dy_coarse
                            ycent_fine   =  ylower + (j_fine-1+jlo + .5d0)*dy_fine
                            eta2         = (ycent_fine-ycent_coarse)/dy_coarse

                            do i_fine = 1, mx_patch
                                xcent_coarse = xlow_coarse + (i_coarse-.5d0)*dx_coarse
                                xcent_fine   =  xlower + (i_fine-1+ilo + .5d0)*dx_fine
                                eta1         = (xcent_fine-xcent_coarse)/dx_coarse

                                if (flaguse(i_fine,j_fine) == 0) then
                                    ! Cell not already set

                                    if (.not.(fine_flag(1,i_coarse,j_coarse))) then
                                        ! This cell has no coarse cells that are dry
                                        hv_fine = valcrse(ivalc(n,i_coarse,j_coarse))         &
                                                        + eta1 * slope(1,i_coarse,j_coarse)   &
                                                        + eta2 * slope(2,i_coarse,j_coarse)
                                        v_fine = hv_fine  / valbig(3*layer-2,i_fine+nrowst-1, j_fine+ncolst-1)
                                        if (v_fine<vel_min(i_coarse,j_coarse) .or.  v_fine>vel_max(i_coarse,j_coarse)) then
                                            fine_flag(n,i_coarse,j_coarse) = .true.
                                            reloop = .true.
                                        else
                                            valbig(n,i_fine+nrowst-1,j_fine+ncolst-1) = hv_fine
                                        endif
                                    endif
                                endif
                            enddo
                        enddo

                    ! Reset momentum to conserve momentum in the cases where we may have
                    ! gained momentum or if velocity bounds were violated
                        if (reloop) then
                  
                            do j_fine  = 1, my_patch
                                ycent_coarse = ylow_coarse + (j_coarse-.5d0)*dy_coarse
                                ycent_fine   =  ylower + (j_fine-1+jlo + .5d0)*dy_fine
                                eta2         = (ycent_fine-ycent_coarse)/dy_coarse
             
                                do i_fine = 1, mx_patch
                                    xcent_coarse = xlow_coarse + (i_coarse-.5d0)*dx_coarse
                                    xcent_fine   =  xlower + (i_fine-1+ilo + .5d0)*dx_fine
                                    eta1         = (xcent_fine-xcent_coarse)/dx_coarse

                                    if (flaguse(i_fine,j_fine) == 0) then
                                        if (fine_flag(1,i_coarse,j_coarse) .or. fine_flag(n,i_coarse,j_coarse)) then
                                            if (fine_mass(i_coarse,j_coarse) > dry_tolerance(layer)) then
                                                h_coarse = valcrse(ivalc(1,i_coarse,j_coarse))
                                                h_count = real(fine_cell_count(i_coarse,j_coarse),kind=8)
                                                h_fine_average = fine_mass(i_coarse,j_coarse) / h_count
                                                divide_mass = max(h_coarse, h_fine_average)
                                                h_fine = valbig(3*layer-2, i_fine + nrowst - 1, j_fine + ncolst - 1)
                                                v_new = valcrse(ivalc(n,i_coarse,j_coarse)) / (divide_mass)

                                                valbig(n,i_fine+nrowst-1,j_fine+ncolst-1) = &
                                                    v_new * valbig(3*layer-2,i_fine+nrowst-1,j_fine+ncolst-1)
                                            else
                                                valbig(n,i_fine+nrowst-1,j_fine+ncolst-1) = 0.d0
                                            endif
                                        endif
                                    endif
                                enddo
                            enddo
                        endif
                    enddo ! Momentum component loop
                enddo ! Layer loop
            enddo ! Coarse i loop
        enddo ! Coarse j loop
        ! **************** End Interpolation *******************
    endif ! end if patch not set

    ! set bcs, whether or not recursive calls needed. set any part of patch that stuck out
    xhi_fine = xlower + (ihi + 1) * dx_fine
    yhi_fine = ylower + (jhi + 1) * dy_fine
    if (patchOnly) then
       call bc2amr(valbig,aux,mx,my,nvar,naux,dx_fine,dy_fine,level,t,   &
                   xlow_fine,xhi_fine,ylow_fine,yhi_fine)
    endif

contains

    integer pure function ivalc(n,i,j)
        implicit none
        integer, intent(in) :: n,i,j
        ivalc = n + nvar*(i-1) + nvar*mx_coarse*(j-1)
    end function ivalc

    ! Index into first component of aux = topo:
    integer pure function iauxc(i,j)
        implicit none
        integer, intent(in) :: i,j
        iauxc = 1 + naux*(i-1) + naux*mx_coarse*(j-1)
    end function iauxc

    ! logical for checking if this patch sticks outside of the domain
    logical pure function sticksout(iplo,iphi,jplo,jphi)
        implicit none
        integer, intent(in) :: iplo,iphi,jplo,jphi
        sticksout = (iplo < 0 .or. jplo < 0 .or. &
                     iphi >= iregsz(level - 1) .or. jphi >= jregsz(level - 1))
    end function sticksout

end subroutine filrecur
