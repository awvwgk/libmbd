! This Source Code Form is subject to the terms of the Mozilla Public
! License, v. 2.0. If a copy of the MPL was not distributed with this
! file, You can obtain one at http://mozilla.org/MPL/2.0/.
module mbd_api

use mbd_system_type, only: mbd_system, mbd_calc
use mbd, only: mbd_damping, &
    mbd_scs_energy, set_damping_parameters, &
    mbd_result, mbd_gradients, scale_TS
use mbd_ts, only: ts_energy
use mbd_common, only: dp, printer
use mbd_vdw_param, only: default_vdw_params, species_index
use mbd_defaults

implicit none

private
public :: mbd_input, mbd_calculation  ! types
public :: mbd_get_damping_parameters, mbd_get_free_vdw_params  ! subroutines

type :: mbd_input
    integer :: comm  ! MPI communicator

    ! which calculation will be done (mbd|ts)
    character(len=30) :: dispersion_type = 'mbd'
    logical :: calculate_forces = .true.
    logical :: calculate_spectrum = .false.

    real(dp) :: ts_ene_acc = TS_ENERGY_ACCURACY  ! accuracy of TS energy
    real(dp) :: ts_f_acc = TS_FORCES_ACCURACY  ! accuracy of TS gradients
    integer :: n_omega_grid = N_FREQUENCY_GRID  ! number of frequency grid points
    ! off-gamma shift of k-points in units of inter-k-point distance
    real(dp) :: k_grid_shift = K_GRID_SHIFT

    ! TS damping parameters
    real(dp) :: ts_d = TS_DAMPING_D
    real(dp) :: ts_sr
    ! MBD damping parameters
    real(dp) :: mbd_a = MBD_DAMPING_A
    real(dp) :: mbd_beta

    integer :: k_grid(3)  ! number of k-points along reciprocal axes
    ! is there vacuum along some axes in a periodic calculation
    logical :: vacuum_axis(3) = [.false., .false., .false.]
    real(dp), allocatable :: free_values(:, :)
    logical :: zero_negative_eigvals = .false.
end type

type mbd_calculation
    private
    type(mbd_system) :: sys
    type(mbd_damping) :: damp
    real(dp), allocatable :: alpha_0(:)
    real(dp), allocatable :: C6(:)
    character(len=30) :: dispersion_type
    type(mbd_calc) :: calc
    type(mbd_result) :: results
    type(mbd_gradients) :: denergy
    logical :: do_gradients
    real(dp), allocatable :: free_values(:, :)
contains
    procedure :: init => mbd_calc_init
    procedure :: destroy => mbd_calc_destroy
    procedure :: update_coords => mbd_calc_update_coords
    procedure :: update_lattice_vectors => mbd_calc_update_lattice_vectors
    procedure :: update_vdw_params_custom => mbd_calc_update_vdw_params_custom
    procedure :: update_vdw_params_from_ratios => &
        mbd_calc_update_vdw_params_from_ratios
    procedure :: get_energy => mbd_calc_get_energy
    procedure :: get_gradients => mbd_calc_get_gradients
    procedure :: get_lattice_derivs => mbd_calc_get_lattice_derivs
    procedure :: get_spectrum_modes => mbd_calc_get_spectrum_modes
    procedure :: get_exception => mbd_calc_get_exception
    procedure :: print_info => mbd_calc_print_info
end type

contains


subroutine mbd_calc_init(this, input)
    class(mbd_calculation), target, intent(out) :: this
    type(mbd_input), intent(in) :: input

    this%sys%comm = input%comm
    this%dispersion_type = input%dispersion_type
    this%do_gradients = input%calculate_forces
    if (input%calculate_spectrum) then
        this%sys%get_eigs = .true.
        this%sys%get_modes = .true.
    end if
    this%calc%param%ts_energy_accuracy = input%ts_ene_acc
    ! TODO ... = input%ts_f_acc
    this%calc%param%n_frequency_grid = input%n_omega_grid
    this%calc%param%k_grid_shift = input%k_grid_shift
    this%calc%param%zero_negative_eigs = input%zero_negative_eigvals
    this%damp%beta = input%mbd_beta
    this%damp%a = input%mbd_a
    this%damp%ts_d = input%ts_d
    this%damp%ts_sr = input%ts_sr
    this%sys%k_grid = input%k_grid
    this%sys%vacuum_axis = input%vacuum_axis
    call this%calc%init_grid()
    this%free_values = input%free_values
    call this%calc%blacs_grid%init()
end subroutine


subroutine mbd_calc_destroy(this)
    class(mbd_calculation), target, intent(out) :: this

    call this%calc%blacs_grid%destroy()
end subroutine


subroutine mbd_calc_update_coords(this, coords)
    class(mbd_calculation), intent(inout) :: this
    real(dp), intent(in) :: coords(:, :)

    this%sys%coords = coords
    call this%sys%init(this%calc)
end subroutine


subroutine mbd_calc_update_lattice_vectors(this, latt_vecs)
    class(mbd_calculation), intent(inout) :: this
    real(dp), intent(in) :: latt_vecs(:, :)

    this%sys%lattice = latt_vecs
    call this%sys%init(this%calc)
end subroutine


subroutine mbd_calc_update_vdw_params_custom(this, alpha_0, C6, r_vdw)
    class(mbd_calculation), intent(inout) :: this
    real(dp), intent(in) :: alpha_0(:)
    real(dp), intent(in) :: C6(:)
    real(dp), intent(in) :: r_vdw(:)

    this%alpha_0 = alpha_0
    this%C6 = C6
    this%damp%r_vdw = r_vdw
end subroutine


subroutine mbd_calc_update_vdw_params_from_ratios(this, ratios)
    class(mbd_calculation), intent(inout) :: this
    real(dp), intent(in) :: ratios(:)

    real(dp), allocatable :: ones(:)
    type(mbd_gradients) :: dX

    allocate (ones(size(ratios)), source=1d0)
    this%alpha_0 = scale_TS(this%free_values(1, :), ratios, ones, 1d0, dX)
    this%C6 = scale_TS(this%free_values(2, :), ratios, ones, 2d0, dX)
    this%damp%r_vdw = scale_TS(this%free_values(3, :), ratios, ones, 1d0/3, dX)
end subroutine


subroutine mbd_calc_get_energy(this, energy)
    class(mbd_calculation), intent(inout) :: this
    real(dp), intent(out) :: energy

    select case (this%dispersion_type)
    case ('mbd')
        if (this%do_gradients) then
            if (allocated(this%denergy%dcoords)) deallocate(this%denergy%dcoords)
            allocate (this%denergy%dcoords(this%sys%siz(), 3))
        end if
        this%results = mbd_scs_energy(this%sys, 'rsscs', this%alpha_0, this%C6, this%damp, this%denergy)
        energy = this%results%energy
    case ('ts')
        energy = ts_energy(this%sys, this%alpha_0, this%C6, this%damp)
    end select
end subroutine


subroutine mbd_calc_get_gradients(this, gradients)  ! 3 by N  dE/dR
    class(mbd_calculation), intent(in) :: this
    real(dp), intent(out) :: gradients(:, :)

    gradients = transpose(this%denergy%dcoords)
end subroutine


subroutine mbd_calc_get_lattice_derivs(this, latt_derivs)  ! 3 by 3  (dE/d{abc}_i)
    class(mbd_calculation), intent(in) :: this
    real(dp), intent(out) :: latt_derivs(:, :)

    ! TODO
end subroutine


subroutine mbd_calc_get_spectrum_modes(this, spectrum, modes)
    class(mbd_calculation), intent(inout) :: this
    real(dp), intent(out) :: spectrum(:)
    real(dp), intent(out), optional :: modes(:, :)
    ! TODO document that this can be called only once

    spectrum = this%results%mode_eigs
    if (present(modes)) then
        modes = this%results%modes
    end if
end subroutine


subroutine mbd_calc_get_exception(this, code, origin, msg)
    class(mbd_calculation), intent(inout) :: this
    integer, intent(out) :: code
    character(50), intent(out) :: origin
    character(150), intent(out) :: msg

    code = this%calc%exc%code
    if (code == 0) return
    origin = this%calc%exc%origin
    msg = this%calc%exc%msg
    this%calc%exc%code = 0
    this%calc%exc%origin = ''
    this%calc%exc%msg = ''
end subroutine


subroutine mbd_calc_print_info(this, info)
    class(mbd_calculation), intent(inout) :: this
    procedure(printer) :: info

    call this%calc%info%print(info)
end subroutine


subroutine mbd_get_damping_parameters(xc, mbd_beta, ts_sr)
    character(len=*), intent(in) :: xc
    real(dp), intent(out) :: mbd_beta, ts_sr

    real(dp) :: d1, d2, d3, d4, d5, d6

    call set_damping_parameters(xc, d1, ts_sr, d2, d3, d4, d5, d6, mbd_beta)
end subroutine


function mbd_get_free_vdw_params(atom_types, table_type) result(free_values)
    character(len=*), intent(in) :: atom_types(:)  ! e.g. ['Ar', 'Ar']
    character(len=*), intent(in) :: table_type  ! either "ts" or "ts_surf"
    ! 3 by N (alpha_0, C6, R_vdw)
    real(dp) :: free_values(3, size(atom_types))

    select case (table_type)
    case ('ts')
        free_values = default_vdw_params(:, species_index(atom_types))
    end select
end function

end module
